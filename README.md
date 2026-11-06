# ResearchDAO: deployment

1. `npm install`
2. `npx hardhat test`
3. `export RPC_URL=<rpc> PRIVATE_KEY=<deployer key>` then `npm run deploy` (note the address).
4. As admin: `setReviewer(addr,true)`, then `createRound(name, tokenAddr, maxBudget, votingSecs, fundingSecs, quorum, reviewThreshold)` using your BOT or USDT address (mind token decimals; USDT is often 6).
5. Edit `frontend/index.html`: set `CONFIG.address`, `CONFIG.chainId`, `CONFIG.decimals`. Serve statically (`npx serve frontend`) or host on IPFS. Open with MetaMask.

Notes: voting is per-wallet, not per-human (Sybil-able; mitigated by quorum, reviewer approval, optional identity attestations). Never upload confidential data: store only public summaries + hashes; keep files off-chain, encrypted/access-controlled if restricted. Contracts are unaudited: audit before mainnet and move admin to a multisig.
# researchDao
