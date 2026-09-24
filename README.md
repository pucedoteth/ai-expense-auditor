# AI Expense Auditor on Ritual

This is an on-chain forensic-accounting assistant built on **Ritual Chain** (testnet, chain ID 1979).

1. A user submits a business expense: amount, category and business purpose.
2. The contract builds an audit prompt and calls Ritual's **LLM precompile (`0x0802`)**. The model is `zai-org/GLM-4.7-FP8`, running inside a TEE.
3. The AI reviews the expense for red flags: amounts that are unusual for the category, a vague purpose, personal items, round numbers, or possible split purchases.
4. The verdict (**Normal**, **Suspicious** or **Unclear**) and a short explanation are stored on-chain in a **public, tamper-proof audit log**.

## Why

Expense fraud is one of the most common forms of occupational fraud. Putting AI-assisted review on-chain means the review itself can be audited: anyone can check which expense was reviewed, when, by which model, and what it concluded.

## Files

- `ExpenseAuditor.sol`: the smart contract (Solidity ^0.8.20)
- `index.html`: a one-page website (MetaMask and ethers.js)

## Status

Built and compiled against the Ritual testnet (chain 1979) precompile interfaces. The testnet has now closed, and this project will be deployed on **Ritual mainnet** at launch. Chain settings and system addresses will be updated if they change.

## Run it

1. Add Ritual Testnet to MetaMask (the website does this for you) and get test RITUAL from https://faucet.ritualfoundation.org
2. Deploy `ExpenseAuditor.sol` with Remix (Injected Provider, MetaMask).
3. Open the website, paste the contract address, click **Deposit 0.5 RITUAL for AI fees**, then submit expenses.

You can share a link that already includes the contract address: `https://<you>.github.io/<repo>/?c=0xYourContract`

## Technical notes

- The LLM request is the full 30-field precompile tuple. The request is built as a struct, and the ABI offset word is removed so the precompile receives the flat encoding.
- User text is JSON-escaped on-chain, so a description can't change the prompt's structure.
- `has_error` is checked before the completion is decoded. Reasoning (`<think>…</think>`) is removed, and the verdict is read from the last `VERDICT:` line.
- The site sends the transaction with a fixed gas limit, because async precompiles can't be simulated.

Built with the [Ritual dApp Skills](https://skills.ritualfoundation.org/) reference.
