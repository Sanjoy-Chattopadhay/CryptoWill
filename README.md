# 🔐 Hybrid CrypWill – Fractional NFT Inheritance with Verifiable Secret Sharing

**Hybrid CrypWill** is a Solidity-based smart contract system designed to enable **secure, verifiable, and trustless inheritance of ERC-721 assets (NFTs)** using a **Pedersen Verifiable Secret Sharing (VSS)** scheme. It ensures that sensitive secrets (e.g., private keys or unlock credentials) can only be reconstructed when a quorum of assigned trustees collaborate, enabling reliable digital asset transfers posthumously.

---

## 📜 Overview

CrypWill allows an NFT holder (testator) to assign a group of **trustees** who each receive a verifiable share of a secret. Once a predefined number of trustees submit valid shares, the original secret can be reconstructed. This secret could unlock wallets, transfer NFTs, or trigger other secure actions off-chain.

All cryptographic operations (secret generation, commitment validation, reconstruction) happen off-chain. The contract records **commitments**, **trustee metadata**, and **reconstruction states** for transparency.

---

## ⚙️ Features

- 🔐 **Pedersen Verifiable Secret Sharing (VSS):** Uses dual polynomials \( F(x), G(x) \) and commitment points to ensure each share is valid without revealing the secret.
- 🧾 **ERC-721 Compatibility:** Supports any ERC-721 compliant NFT for inheritance.
- 👥 **Multi-trustee Inheritance:** Secret is split among trustees with a minimum quorum required to reconstruct.
- 📦 **On-chain Commitments:** Share commitments and trustee data stored for public auditability.
- ⛓️ **Hybrid Design:** On-chain contract for control logic; cryptographic computations handled securely off-chain.
- 🚫 **Emergency Stop / Timeout Mechanisms** (optional): Can halt or reset the inheritance process in case of disputes.

---

## 📄 ERC-721 Inheritance Flow

1. **Registration**:
    - Testator registers the NFT (ERC-721 token ID + contract address).
    - Submits commitment values \( C_i = g^{F(i)} h^{G(i)} \) for each trustee.
2. **Distribution**:
    - Trustees receive their shares \( F(i) \) and blinding factors \( G(i) \) off-chain.
    - Each trustee verifies their share using the public commitments.
3. **Activation**:
    - Upon testator's death or trigger event, trustees submit their shares back.
    - If quorum is met (e.g., 3 of 5), the secret is reconstructed off-chain and used to perform final asset unlocking or transfer.
4. **NFT Transfer**:
    - The contract can optionally hold and transfer the ERC-721 token to the heir(s) or unlock access using the secret.

---
