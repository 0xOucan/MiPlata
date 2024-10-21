"use client";

import { useState } from "react";
import { useAccount, useContractRead, useContractWrite } from "wagmi";
import { Address, AddressInput, IntegerInput } from "~~/components/scaffold-eth";
import { useDeployedContractInfo } from "~~/hooks/scaffold-eth";

const Home: React.FC = () => {
  const { address: connectedAddress } = useAccount();
  const [investmentAmount, setInvestmentAmount] = useState<string>("");
  const [investmentType, setInvestmentType] = useState<number>(0);
  const [selectedInvestmentId, setSelectedInvestmentId] = useState<string>("");

  const { data: deployedContractData } = useDeployedContractInfo("MiPlata");

  // Lectura de datos del contrato
  const { data: totalUsers } = useContractRead({
    address: deployedContractData?.address,
    abi: deployedContractData?.abi,
    functionName: "getTotalUsers",
  });

  const { data: userInvestments } = useContractRead({
    address: deployedContractData?.address,
    abi: deployedContractData?.abi,
    functionName: "getUserInvestments",
    args: [connectedAddress],
  });

  // Escritura en el contrato
  const { write: invest } = useContractWrite({
    address: deployedContractData?.address,
    abi: deployedContractData?.abi,
    functionName: "invest",
  });

  const { write: withdraw } = useContractWrite({
    address: deployedContractData?.address,
    abi: deployedContractData?.abi,
    functionName: "withdraw",
  });

  return (
    <div className="flex flex-col items-center pt-10">
      <h1 className="text-4xl font-bold mb-8">MiPlata DApp</h1>

      <div className="mb-8">
        <h2 className="text-2xl mb-4">Realizar inversión</h2>
        <IntegerInput
          value={investmentAmount}
          onChange={value => setInvestmentAmount(value)}
          placeholder="Cantidad a invertir (USDC)"
        />
        <select
          value={investmentType}
          onChange={e => setInvestmentType(Number(e.target.value))}
          className="mt-2 p-2 border rounded"
        >
          <option value={0}>Arriesgado</option>
          <option value={1}>Moderado</option>
          <option value={2}>Conservador</option>
        </select>
        <button
          onClick={() => invest({ args: [investmentAmount, investmentType] })}
          className="mt-2 bg-blue-500 text-white p-2 rounded"
        >
          Invertir
        </button>
      </div>

      <div className="mb-8">
        <h2 className="text-2xl mb-4">Retirar inversión</h2>
        <IntegerInput
          value={selectedInvestmentId}
          onChange={value => setSelectedInvestmentId(value)}
          placeholder="ID de la inversión"
        />
        <button
          onClick={() => withdraw({ args: [selectedInvestmentId] })}
          className="mt-2 bg-red-500 text-white p-2 rounded"
        >
          Retirar
        </button>
      </div>

      <div className="mb-8">
        <h2 className="text-2xl mb-4">Tus inversiones</h2>
        {userInvestments && userInvestments.map((investment, index) => (
          <div key={index} className="mb-2">
            ID: {investment.investmentId.toString()}, 
            Tipo: {["Arriesgado", "Moderado", "Conservador"][investment.investmentType]}, 
            USDC: {investment.usdcDeposited.toString()}
          </div>
        ))}
      </div>

      <div>
        <h2 className="text-2xl mb-4">Estadísticas</h2>
        <p>Total de usuarios: {totalUsers?.toString()}</p>
      </div>
    </div>
  );
};

export default Home;
