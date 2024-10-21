// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

// Importaciones de OpenZeppelin y otros contratos
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";
import "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

// Importar las bibliotecas de Uniswap V3
import "@uniswap/v3-core/contracts/libraries/TickMath.sol";
import "@uniswap/v3-periphery/contracts/libraries/LiquidityAmounts.sol";

contract MiPlata is Ownable, ReentrancyGuard, AutomationCompatibleInterface, Pausable {
    using SafeERC20 for IERC20;

    // Enumeracion para los tipos de inversion
    enum InvestmentType { Risky, Moderate, Conservative }

    // Estructura para cada inversion de un usuario
    struct UserInvestment {
        uint256 investmentId;
        InvestmentType investmentType;
        uint256 usdcDeposited;
        uint256 wethBorrowed;
        uint256 lastAutoCompound;
        uint256 amplitude;
        uint256 tokenId; // ID del NFT de la posicion en Uniswap V3
        uint256 lastEthPrice; // Ultimo precio de ETH/USD registrado
        uint256 timestamp; // Marca de tiempo de la inversion
    }

    // Variables de contratos externos
    IERC20 public usdc;
    IERC20 public weth;
    ISwapRouter public uniswapRouter;
    IPool public aavePool;
    AggregatorV3Interface public ethUsdPriceFeed;
    IUniswapV3Pool public uniswapPool;
    INonfungiblePositionManager public positionManager;

    // Parametros de inversion
    uint256 public constant FEE_PERCENTAGE = 25; // 0.25% representado como 25/10000
    uint256 public constant MINIMUM_INVESTMENT = 5 * 1e6; // 5 USDC (6 decimales)
    uint256 public constant MAX_INVESTMENT = 100 * 1e6; // 100 USDC (6 decimales)
    uint256 public constant REBALANCE_THRESHOLD = 300; // 3% (representado como 300/10000)
    uint256 public constant VARIATION_HIGH = 750; // 7.5%
    uint256 public constant VARIATION_MEDIUM = 550; // 5.5%
    uint256 public constant COMPOUND_THRESHOLD = 100 * 1e6; // 100 USDC

    // Amplitudes para Uniswap V3
    uint256 public constant AMPLITUDE_RISKY = 500; // Representa 5%
    uint256 public constant AMPLITUDE_MODERATE = 750; // 7.5%
    uint256 public constant AMPLITUDE_CONSERVATIVE = 1000; // 10%

    // Direccion para colectar las comisiones
    address public feeCollector;

    // Estructuras de datos para gestionar inversiones
    mapping(address => UserInvestment[]) public investments;
    mapping(address => uint256) public userInvestmentCounters;
    address[] public userAddresses;
    uint256 public lastProcessedUserIndex;

    // Eventos
    event InvestmentMade(address indexed user, uint256 investmentId, uint256 amount, InvestmentType investmentType, uint256 amplitude);
    event Withdrawn(address indexed user, uint256 investmentId, uint256 amount);
    event Rebalanced(address indexed user, uint256 investmentId, uint256 timestamp);
    event Compounded(uint256 timestamp, uint256 amount);
    event EmergencyWithdrawal(address indexed owner, uint256 usdcAmount, uint256 wethAmount, uint256 timestamp);

    // Agregar esta linea para declarar accumulatedFees
    uint256 public accumulatedFees;

    constructor(
        address _usdc,
        address _weth,
        address _uniswapRouter,
        address _aavePool,
        address _ethUsdPriceFeed,
        address _uniswapPool,
        address _positionManager,
        address _feeCollector
    ) Ownable(msg.sender) {
        usdc = IERC20(_usdc);
        weth = IERC20(_weth);
        uniswapRouter = ISwapRouter(_uniswapRouter);
        aavePool = IPool(_aavePool);
        ethUsdPriceFeed = AggregatorV3Interface(_ethUsdPriceFeed);
        uniswapPool = IUniswapV3Pool(_uniswapPool);
        positionManager = INonfungiblePositionManager(_positionManager);
        feeCollector = _feeCollector;
    }

    /**
     * @dev Permite a un usuario invertir USDC en la plataforma.
     * @param amount La cantidad de USDC a invertir (6 decimales).
     * @param investmentType El tipo de estrategia de inversion seleccionada.
     */
    function invest(uint256 amount, InvestmentType investmentType)
        external
        nonReentrant
        whenNotPaused
    {
        require(amount >= MINIMUM_INVESTMENT, "Monto minimo no alcanzado");
        require(amount <= MAX_INVESTMENT, "Monto maximo excedido");

        usdc.safeTransferFrom(msg.sender, address(this), amount);

        // Calcular y transferir la comision
        uint256 fee = (amount * FEE_PERCENTAGE) / 10000; // 0.25%
        uint256 netAmount = amount - fee;
        usdc.safeTransfer(feeCollector, fee);

        // Asignar fondos: 62.5% a Aave como colateral, 37.5% para prestamo y LP
        uint256 usdcCollateral = (netAmount * 6250) / 10000; // 62.5%
        uint256 borrowAmount = (netAmount * 3750) / 10000; // 37.5%

        // Depositar USDC en Aave
        depositToAave(usdcCollateral);

        // Pedir prestado WETH de Aave
        uint256 wethBorrowed = borrowFromAave(borrowAmount);

        // Obtener la amplitud basada en la estrategia
        uint256 amplitude = getAmplitude(investmentType);

        // Crear una posicion en Uniswap V3
        uint256 tokenId = createUniswapPosition(usdcCollateral, wethBorrowed, amplitude);

        // Obtener el precio actual de ETH/USD
        uint256 currentEthPrice = getETHUSDPrice();

        // Registrar la inversion del usuario
        uint256 investmentId = userInvestmentCounters[msg.sender]++;
        UserInvestment memory newInvestment = UserInvestment({
            investmentId: investmentId,
            investmentType: investmentType,
            usdcDeposited: usdcCollateral,
            wethBorrowed: wethBorrowed,
            lastAutoCompound: block.timestamp,
            amplitude: amplitude,
            tokenId: tokenId,
            lastEthPrice: currentEthPrice,
            timestamp: block.timestamp
        });

        investments[msg.sender].push(newInvestment);

        // Agregar al usuario a la lista si es la primera inversion
        if (investments[msg.sender].length == 1) {
            userAddresses.push(msg.sender);
        }

        emit InvestmentMade(msg.sender, investmentId, netAmount, investmentType, amplitude);
    }

    /**
     * @dev Permite a un usuario retirar una inversion especifica.
     * @param investmentId El ID de la inversion a retirar.
     */
    function withdraw(uint256 investmentId) external nonReentrant whenNotPaused {
        UserInvestment[] storage userInvestments = investments[msg.sender];
        uint256 index = getInvestmentIndex(msg.sender, investmentId);
        UserInvestment storage investment = userInvestments[index];
        require(investment.usdcDeposited > 0, "No hay inversion activa");

        // Cerrar la posicion en Uniswap V3
        closeUniswapPosition(investment.tokenId);

        // Repagar el prestamo en Aave
        repayAaveLoan(investment.wethBorrowed);

        // Retirar el colateral de Aave
        withdrawFromAave(investment.usdcDeposited);

        // Calcular el total a transferir al usuario
        uint256 wethBalance = weth.balanceOf(address(this));
        uint256 usdcFromWeth = swapWETHtoUSDC(wethBalance);
        uint256 totalAmount = investment.usdcDeposited + usdcFromWeth;

        // Actualizar el total de inversiones
        // Nota: Esto puede necesitar ajustes dependiendo de la logica de contabilidad interna
        // Aqui asumimos que el totalInvestment se decrementa por el netAmount (sin comisiones)
        // Ajusta segun tu logica especifica
        // totalInvestment -= investment.usdcDeposited + wethFromBorrow;

        // Eliminar la inversion del array
        userInvestments[index] = userInvestments[userInvestments.length - 1];
        userInvestments.pop();

        // Eliminar al usuario de userAddresses si no tiene mas inversiones
        if (userInvestments.length == 0) {
            for (uint256 i = 0; i < userAddresses.length; i++) {
                if (userAddresses[i] == msg.sender) {
                    userAddresses[i] = userAddresses[userAddresses.length - 1];
                    userAddresses.pop();
                    break;
                }
            }
        }

        // Transferir USDC al usuario
        usdc.safeTransfer(msg.sender, totalAmount);

        emit Withdrawn(msg.sender, investmentId, totalAmount);
    }

    /**
     * @dev Deposita USDC en Aave.
     * @param amount La cantidad de USDC a depositar.
     */
    function depositToAave(uint256 amount) internal {
        usdc.approve(address(aavePool), amount);
        aavePool.supply(address(usdc), amount, address(this), 0);
    }

    /**
     * @dev Pide prestado WETH de Aave.
     * @param amount La cantidad de WETH a pedir prestado.
     * @return La cantidad de WETH pedida prestada.
     */
    function borrowFromAave(uint256 amount) internal returns (uint256) {
        aavePool.borrow(address(weth), amount, 2, 0, address(this));
        return amount;
    }

    /**
     * @dev Repaga un prestamo de Aave.
     * @param amount La cantidad de WETH a repagar.
     */
    function repayAaveLoan(uint256 amount) internal {
        weth.approve(address(aavePool), amount);
        aavePool.repay(address(weth), amount, 2, address(this));
    }

    /**
     * @dev Retira USDC de Aave.
     * @param amount La cantidad de USDC a retirar.
     */
    function withdrawFromAave(uint256 amount) internal {
        aavePool.withdraw(address(usdc), amount, address(this));
    }

    /**
     * @dev Crea una posicion en Uniswap V3.
     * @param usdcAmount La cantidad de USDC para proporcionar liquidez.
     * @param wethAmount La cantidad de WETH para proporcionar liquidez.
     * @param amplitude La amplitud del rango de precios para la liquidez.
     * @return tokenId El ID del NFT de la posicion creada.
     */
    function createUniswapPosition(
        uint256 usdcAmount, 
        uint256 wethAmount, 
        uint256 amplitude
    ) internal returns (uint256 tokenId) {
        usdc.approve(address(positionManager), usdcAmount);
        weth.approve(address(positionManager), wethAmount);

        (, int24 currentTick, , , , , ) = uniswapPool.slot0();
        int24 tickSpacing = uniswapPool.tickSpacing();
        
        // Convertir amplitude a int24 de forma segura
        require(amplitude <= uint256(int256(type(int24).max)), "Amplitude too large");
        int24 amplitudeInt24 = int24(int256(amplitude));
        
        int24 tickLower = currentTick - amplitudeInt24 * tickSpacing;
        int24 tickUpper = currentTick + amplitudeInt24 * tickSpacing;

        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: address(usdc),
            token1: address(weth),
            fee: 3000, // 0.3%
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: usdcAmount,
            amount1Desired: wethAmount,
            amount0Min: (usdcAmount * 99) / 100, // 1% slippage tolerance
            amount1Min: (wethAmount * 99) / 100, // 1% slippage tolerance
            recipient: address(this),
            deadline: block.timestamp + 15 minutes
        });

        (tokenId, , , ) = positionManager.mint(params);
        require(tokenId != 0, "Error al crear posicion en Uniswap");
    }

    /**
     * @dev Cierra una posicion en Uniswap V3.
     * @param tokenId El ID del NFT de la posicion a cerrar.
     */
    function closeUniswapPosition(uint256 tokenId) internal {
        // Verificar que el tokenId pertenece al contrato
        (, , address tokenOwner, , , , , , , , , ) = positionManager.positions(tokenId);
        require(tokenOwner == address(this), "Token ID no pertenece al contrato");

        // Obtener la liquidez actual
        (, , , , , , , uint128 liquidity, , , , ) = positionManager.positions(tokenId);
        require(liquidity > 0, "No hay liquidez en la posicion");

        // Decrease Liquidity
        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = INonfungiblePositionManager.DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 15 minutes
        });
        positionManager.decreaseLiquidity(decreaseParams);

        // Collect tokens
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });
        positionManager.collect(collectParams);

        // Burn the NFT
        positionManager.burn(tokenId);
    }

    /**
     * @dev Cambia WETH a USDC usando Uniswap V3.
     * @param wethAmount La cantidad de WETH a cambiar.
     * @return La cantidad de USDC recibida.
     */
    function swapWETHtoUSDC(uint256 wethAmount) internal returns (uint256) {
        weth.approve(address(uniswapRouter), wethAmount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(usdc),
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp + 15 minutes,
            amountIn: wethAmount,
            amountOutMinimum: 0, // Puedes ajustar esto segun tu tolerancia al deslizamiento
            sqrtPriceLimitX96: 0
        });

        return uniswapRouter.exactInputSingle(params);
    }

    /**
     * @dev Cambia USDC a WETH usando Uniswap V3.
     * @param usdcAmount La cantidad de USDC a cambiar.
     * @return La cantidad de WETH recibida.
     */
    function swapUSDCtoWETH(uint256 usdcAmount) internal returns (uint256) {
        usdc.approve(address(uniswapRouter), usdcAmount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdc),
            tokenOut: address(weth),
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp + 15 minutes,
            amountIn: usdcAmount,
            amountOutMinimum: 0, // Puedes ajustar esto segun tu tolerancia al deslizamiento
            sqrtPriceLimitX96: 0
        });

        return uniswapRouter.exactInputSingle(params);
    }

    /**
     * @dev Obtiene la amplitud basada en el tipo de inversion.
     * @param investmentType El tipo de inversion.
     * @return La amplitud correspondiente.
     */
    function getAmplitude(InvestmentType investmentType) internal pure returns (uint256) {
        if (investmentType == InvestmentType.Risky) return AMPLITUDE_RISKY;
        if (investmentType == InvestmentType.Moderate) return AMPLITUDE_MODERATE;
        return AMPLITUDE_CONSERVATIVE;
    }

    /**
     * @dev Obtiene el indice de una inversion especifica del usuario.
     * @param user El usuario.
     * @param investmentId El ID de la inversion.
     * @return El indice de la inversion en el array del usuario.
     */
    function getInvestmentIndex(address user, uint256 investmentId) internal view returns (uint256) {
        UserInvestment[] storage userInvestments = investments[user];
        for (uint256 i = 0; i < userInvestments.length; i++) {
            if (userInvestments[i].investmentId == investmentId) {
                return i;
            }
        }
        revert("Inversion no encontrada");
    }

    /**
     * @dev Obtiene el precio actual de ETH en USD desde Chainlink.
     * @return El precio de ETH/USD con 8 decimales.
     */
    function getETHUSDPrice() internal view returns (uint256) {
        (, int256 price, , uint256 updatedAt, ) = ethUsdPriceFeed.latestRoundData();
        require(price > 0, "Precio ETH/USD invalido");
        require(block.timestamp - updatedAt < 1 hours, "Precio ETH/USD desactualizado");
        return uint256(price); // 8 decimales
    }

    /**
     * @dev Implementación de la función checkUpkeep de Chainlink Automation.
     * @return upkeepNeeded Indica si se necesita realizar mantenimiento.
     * @return performData Datos para realizar el mantenimiento.
     */
    function checkUpkeep(bytes calldata /* checkData */) external view override returns (bool upkeepNeeded, bytes memory performData) {
        bool needsRebalance = false;
        bool needsCompound = false;

        // Verificar si hay suficientes comisiones acumuladas para componer
        if (getAccumulatedFees() >= COMPOUND_THRESHOLD) {
            needsCompound = true;
        }

        // Verificar si alguna inversión necesita reequilibrio
        for (uint256 i = 0; i < userAddresses.length; i++) {
            address user = userAddresses[i];
            UserInvestment[] storage userInvestments = investments[user];
            for (uint256 j = 0; j < userInvestments.length; j++) {
                UserInvestment storage investment = userInvestments[j];
                uint256 currentPrice = getETHUSDPrice();
                uint256 priceChange = calculatePriceVariation(investment.lastEthPrice, currentPrice);
                if (priceChange >= REBALANCE_THRESHOLD) {
                    needsRebalance = true;
                    break;
                }
            }
            if (needsRebalance) break;
        }

        upkeepNeeded = needsRebalance || needsCompound;

        if (upkeepNeeded) {
            performData = abi.encode(needsRebalance, needsCompound);
        }

        return (upkeepNeeded, performData);
    }

    /**
     * @dev Implementacion de la funcion performUpkeep de Chainlink Automation.
     * @param performData Datos para realizar el mantenimiento.
     */
    function performUpkeep(bytes calldata performData) external override {
        (bool needsRebalance, bool needsCompound) = abi.decode(performData, (bool, bool));

        if (needsRebalance) {
            rebalanceAll();
        }

        if (needsCompound) {
            compoundAll();
        }
    }

    /**
     * @dev Reequilibra todas las inversiones que lo requieran.
     */
    function rebalanceAll() internal {
        for (uint256 i = 0; i < userAddresses.length; i++) {
            address user = userAddresses[i];
            UserInvestment[] storage userInvestments = investments[user];
            for (uint256 j = 0; j < userInvestments.length; j++) {
                UserInvestment storage investment = userInvestments[j];
                uint256 currentPrice = getETHUSDPrice();
                uint256 priceChange = calculatePriceVariation(investment.lastEthPrice, currentPrice);
                if (priceChange >= REBALANCE_THRESHOLD) {
                    // Cerrar la posicion existente
                    closeUniswapPosition(investment.tokenId);

                    // Repagar el prestamo en Aave
                    repayAaveLoan(investment.wethBorrowed);

                    // Retirar el colateral de Aave
                    withdrawFromAave(investment.usdcDeposited);

                    // Reasignar fondos
                    uint256 totalAmount = investment.usdcDeposited + swapWETHtoUSDC(weth.balanceOf(address(this)));

                    // Calcular y transferir la comision
                    uint256 fee = (totalAmount * FEE_PERCENTAGE) / 10000;
                    uint256 netAmount = totalAmount - fee;
                    usdc.safeTransfer(feeCollector, fee);

                    // Asignar nuevamente 62.5% a Aave y 37.5% para prestamo y LP
                    uint256 usdcCollateral = (netAmount * 6250) / 10000;
                    uint256 borrowAmount = (netAmount * 3750) / 10000;

                    // Depositar nuevamente en Aave
                    depositToAave(usdcCollateral);

                    // Pedir prestado WETH de Aave
                    uint256 wethBorrowed = borrowFromAave(borrowAmount);

                    // Crear una nueva posicion en Uniswap V3
                    uint256 newTokenId = createUniswapPosition(usdcCollateral, wethBorrowed, investment.amplitude);

                    // Actualizar la inversion
                    investment.usdcDeposited = usdcCollateral;
                    investment.wethBorrowed = wethBorrowed;
                    investment.tokenId = newTokenId;
                    investment.lastEthPrice = currentPrice;
                    investment.lastAutoCompound = block.timestamp;

                    emit Rebalanced(user, investment.investmentId, block.timestamp);
                }
            }
        }
    }

    /**
     * @dev Realiza la autocomposicion de las fees acumuladas.
     */
    function compoundAll() internal {
        uint256 fees = getAccumulatedFees();
        require(fees >= COMPOUND_THRESHOLD, "No hay suficientes fees para componer");

        // Resetear las fees acumuladas
        accumulatedFees = 0;

        // Cambiar parte de las fees a WETH y proporcionar liquidez nuevamente
        uint256 halfFees = fees / 2;
        uint256 wethAmount = swapUSDCtoWETH(halfFees);
        uint256 usdcAmount = halfFees;

        // Crear una nueva posicion en Uniswap V3 con las fees
        createUniswapPosition(usdcAmount, wethAmount, AMPLITUDE_CONSERVATIVE);

        emit Compounded(block.timestamp, fees);
    }

    /**
     * @dev Calcula la variacion porcentual del precio de ETH.
     * @param lastPrice El ultimo precio registrado de ETH.
     * @param currentPrice El precio actual de ETH.
     * @return La variacion porcentual representada como un entero (ej. 750 para 7.5%).
     */
    function calculatePriceVariation(uint256 lastPrice, uint256 currentPrice) internal pure returns (uint256) {
        if (currentPrice >= lastPrice) {
            return ((currentPrice - lastPrice) * 10000) / lastPrice;
        } else {
            return ((lastPrice - currentPrice) * 10000) / lastPrice;
        }
    }

    /**
     * @dev Obtiene las fees acumuladas para la autocomposicion.
     * @return Las fees acumuladas en USDC.
     */
    function getAccumulatedFees() internal view returns (uint256) {
        return accumulatedFees;
    }

    /**
     * @dev Emergencia: permite al propietario retirar todos los fondos del contrato.
     */
    function emergencyWithdraw() external onlyOwner {
        uint256 usdcBalance = usdc.balanceOf(address(this));
        uint256 wethBalance = weth.balanceOf(address(this));

        if (usdcBalance > 0) {
            usdc.safeTransfer(owner(), usdcBalance);
        }

        if (wethBalance > 0) {
            weth.safeTransfer(owner(), wethBalance);
        }

        emit EmergencyWithdrawal(owner(), usdcBalance, wethBalance, block.timestamp);
    }

    /**
     * @dev Pausa todas las operaciones del contrato.
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Reanuda todas las operaciones del contrato.
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Asegura que el contrato tenga la aprobacion necesaria para gastar tokens.
     * @param token El token a aprobar.
     * @param spender La direccion que recibira la aprobacion.
     * @param amount La cantidad a aprobar.
     */
    function ensureApproval(IERC20 token, address spender, uint256 amount) internal {
        uint256 currentAllowance = token.allowance(address(this), spender);
        if (currentAllowance < amount) {
            token.safeIncreaseAllowance(spender, type(uint256).max - currentAllowance);
        }
    }

    /**
     * @dev Configura la direccion del colector de fees.
     * @param _feeCollector La nueva direccion del colector de fees.
     */
    function setFeeCollector(address _feeCollector) external onlyOwner {
        feeCollector = _feeCollector;
    }

    /**
     * @dev Obtiene el valor total de una inversion en USDC.
     * @param investmentId El ID de la inversion.
     * @return El valor total de la inversion en USDC.
     */
    function getInvestmentValue(uint256 investmentId) external view returns (uint256) {
        UserInvestment storage investment = investments[msg.sender][getInvestmentIndex(msg.sender, investmentId)];

        // Calcular el valor de la posicion LP
        uint256 lpValue = getCurrentLpValue(investment.tokenId);

        // Obtener el valor del colateral y el valor del prestamo
        uint256 collateralValue = investment.usdcDeposited;
        uint256 loanValue = investment.wethBorrowed * getETHUSDPrice() / 1e8; // Convertir WETH a USDC

        // Valor total de la inversion
        uint256 totalValue = lpValue + collateralValue - loanValue;

        return totalValue;
    }

    /**
     * @dev Calcula el valor actual de una posicion LP en USDC.
     * @param tokenId El ID del NFT de la posicion en Uniswap V3.
     * @return El valor total de la posicion LP en USDC.
     */
    function getCurrentLpValue(uint256 tokenId) internal view returns (uint256) {
        (uint256 amountUSDC, uint256 amountWETH) = getAmountsFromPosition(tokenId);
        uint256 ethPrice = getETHUSDPrice(); // 8 decimales
        uint256 wethValueInUSDC = (amountWETH * ethPrice) / 1e8;
        uint256 totalLpValue = amountUSDC + wethValueInUSDC;
        return totalLpValue;
    }

    /**
     * @dev Obtiene las cantidades de USDC y WETH de una posicion en Uniswap V3.
     * @param tokenId El ID del NFT de la posicion.
     * @return amountUSDC La cantidad de USDC en la posicion.
     * @return amountWETH La cantidad de WETH en la posicion.
     */
    function getAmountsFromPosition(uint256 tokenId) internal view returns (uint256 amountUSDC, uint256 amountWETH) {
        (, , , , , , , uint128 liquidity, , , , ) = positionManager.positions(tokenId);
        if (liquidity == 0) {
            return (0, 0);
        }

        (uint160 sqrtPriceX96, , , , , , ) = uniswapPool.slot0();
        (uint160 sqrtRatioAX96, ) = getSqrtRatios(tokenId);

        amountUSDC = LiquidityAmounts.getAmount0ForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            liquidity
        );

        amountWETH = LiquidityAmounts.getAmount1ForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            liquidity
        );
    }

    /**
     * @dev Obtiene los valores de sqrtRatioAX96 y sqrtRatioBX96 para una posicion.
     * @param tokenId El ID del NFT de la posicion.
     * @return sqrtRatioAX96 El valor de sqrtRatioAX96.
     * @return sqrtRatioBX96 El valor de sqrtRatioBX96.
     */
    function getSqrtRatios(uint256 tokenId) internal view returns (uint160 sqrtRatioAX96, uint160 sqrtRatioBX96) {
        (, , , , , int24 tickLower, int24 tickUpper, , , , , ) = positionManager.positions(tokenId);
        sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);
    }

    /**
     * @dev Obtiene el total de inversiones realizadas.
     * @return El numero total de usuarios con inversiones.
     */
    function getTotalUsers() external view returns (uint256) {
        return userAddresses.length;
    }

    /**
     * @dev Obtiene todas las inversiones de un usuario.
     * @param user La direccion del usuario.
     * @return Un array de inversiones del usuario.
     */
    function getUserInvestments(address user) external view returns (UserInvestment[] memory) {
        return investments[user];
    }
}
