export interface NetworkAddresses {
  poolManager: string;
  poolSwapTest: string;
  poolModifyLiquidityTest: string;
  universalRouter: string;
  positionManager: string;
  stateView: string;
  quoter: string;
  permit2: string;
}

const SEPOLIA_ADDRESSES: NetworkAddresses = {
  poolManager: "0xE03A1074c86CFeDd5C142C4F04F1a1536e203543",
  poolSwapTest: "0x9B6B46E2C869Aa39918DB7f52F5557fE577b6Eee",
  poolModifyLiquidityTest: "0x0C478023803A644c94C4cE1c1e7B9A087E411b0a",
  universalRouter: "0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b",
  positionManager: "0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4",
  stateView: "0xe1dD9C3FA50eDb962E442F60dfbc432E24537E4C",
  quoter: "0x61B3f2011a92D183c7dbaDbDa940a7555ccF9227",
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
};

const NETWORKS_BY_CHAIN_ID: Record<number, NetworkAddresses> = {
  11155111: SEPOLIA_ADDRESSES,
};

export function getNetworkAddresses(chainId: number | string | undefined): NetworkAddresses | undefined {
  if (chainId === undefined) {
    return undefined;
  }

  const numericId = typeof chainId === "string" ? Number(chainId) : chainId;
  return NETWORKS_BY_CHAIN_ID[numericId];
}
