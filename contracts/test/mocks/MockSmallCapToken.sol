// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHypowToken} from "../../src/interfaces/IHypowToken.sol";

/// @notice Minimal IHypowToken implementation with a configurable CAP for use
///         in tests that need to exercise the cap-edge truncation logic
///         without minting 1.6M times to reach the real 21B cap.
///         Same minter-gated semantics as HypowToken; just smaller.
contract MockSmallCapToken is IHypowToken {
    string public constant override name = "MockCapToken";
    string public constant override symbol = "MOCK";
    uint8 public constant override decimals = 18;

    uint256 public immutable override CAP;
    address public immutable override minter;

    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor(address _minter, uint256 _cap) {
        require(_minter != address(0), "minter zero");
        require(_cap > 0, "cap zero");
        minter = _minter;
        CAP = _cap;
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
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external override returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= value, "allowance");
            unchecked {
                allowance[from][msg.sender] = allowed - value;
            }
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(to != address(0), "to zero");
        uint256 bal = balanceOf[from];
        require(bal >= value, "balance");
        unchecked {
            balanceOf[from] = bal - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }
}
