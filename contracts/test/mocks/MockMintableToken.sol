// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHypowToken} from "../../src/interfaces/IHypowToken.sol";

/// @notice Minimal IHypowToken for claim() symbolic proofs. Its `mint` mirrors
///         HypowToken.mint exactly (minter gate, zero-address guard, zero-amount
///         no-op, CAP clamp) — the real token's mint is itself proven correct by
///         HypowToken.symbolic, so these claim proofs faithfully exercise the same
///         behavior. The ONLY deviation is `setMinter`: the real token fixes its
///         minter as an immutable at construction, which would require predicting
///         the minter's deploy address — impossible under Halmos's synthetic
///         CREATE addressing. A post-deploy setter breaks that cycle without
///         changing any behavior the claim proofs depend on.
contract MockMintableToken is IHypowToken {
    string public constant override name = "Mock";
    string public constant override symbol = "MOCK";
    uint8 public constant override decimals = 18;
    uint256 public constant override CAP = 21_000_000_000 * 1e18;

    address public override minter;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    function setMinter(address m) external {
        minter = m;
    }

    function mint(address to, uint256 amount) external override {
        require(msg.sender == minter, "not minter");
        require(to != address(0), "to zero");
        if (amount == 0) return;
        uint256 newSupply = totalSupply + amount;
        require(newSupply <= CAP, "exceeds cap");
        totalSupply = newSupply;
        unchecked {
            balanceOf[to] += amount;
        }
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external override returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        allowance[from][msg.sender] -= value;
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }
}
