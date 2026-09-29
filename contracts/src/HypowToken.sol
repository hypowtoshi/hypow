// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHypowToken} from "./interfaces/IHypowToken.sol";

/// @title HypowToken
/// @notice HIP-1 token (EVM-side ERC-20 mirror). Immutable. No admin, no governance.
///         A single minter is authorized at deployment and the authorization is irrevocable.
///         The minter cannot be changed; the cap cannot be raised; the name and symbol cannot be edited.
contract HypowToken is IHypowToken {
    string public constant override name = "Hypow";
    string public constant override symbol = "HYPOW";
    uint8 public constant override decimals = 18;

    /// @notice Fixed supply cap, denominated in token wei (18 decimals).
    uint256 public constant override CAP = 21_000_000_000 * 1e18;

    /// @notice The single authorized minter. Set at deployment, immutable.
    address public immutable override minter;

    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor(address _minter) {
        require(_minter != address(0), "minter zero");
        minter = _minter;
    }

    function mint(address to, uint256 amount) external override {
        require(msg.sender == minter, "not minter");
        require(to != address(0), "to zero");
        if (amount == 0) return; // hygiene: no zero-value Transfer
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
