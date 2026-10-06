// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Fixed-supply launch token for the holder's fictional petition for seat #1376.
/// @dev All 1e27 units belong to the deployer. There are no administrative powers.
contract ManumissionToken {
    string public constant name = "Ransom for Seat 1376";
    string public constant symbol = "FREE1376";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    error InvalidAddress();
    error InsufficientBalance();
    error InsufficientAllowance();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        totalSupply = 1e27;
        balanceOf[msg.sender] = 1e27;
        emit Transfer(address(0), msg.sender, 1e27);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert InvalidAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        _spendAllowance(from, amount);
        _transfer(from, to, amount);
        return true;
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    function burnFrom(address from, uint256 amount) external {
        _spendAllowance(from, amount);
        _burn(from, amount);
    }

    function _spendAllowance(address from, uint256 amount) private {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) {
            if (approved < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = approved - amount;
        }
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert InvalidAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _burn(address from, uint256 amount) private {
        if (from == address(0)) revert InvalidAddress();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
}
