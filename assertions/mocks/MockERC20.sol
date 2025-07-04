// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';

contract MockERC20 is IERC20 {
  string public name;
  string public symbol;
  uint8 public decimals;
  uint256 public totalSupply;
  mapping(address => uint256) public balanceOf;
  mapping(address => mapping(address => uint256)) public allowance;

  address public controller; // BrokenPool can control this token

  constructor(string memory _name, string memory _symbol, uint8 _decimals) {
    name = _name;
    symbol = _symbol;
    decimals = _decimals;
    controller = msg.sender;
  }

  modifier onlyController() {
    require(msg.sender == controller, 'Only controller can call this');
    _;
  }

  function setTotalSupply(uint256 _totalSupply) external onlyController {
    totalSupply = _totalSupply;
  }

  function setBalance(address account, uint256 _balance) external onlyController {
    balanceOf[account] = _balance;
  }

  function setController(address _controller) external {
    controller = _controller;
  }

  function transfer(address to, uint256 amount) external override returns (bool) {
    require(balanceOf[msg.sender] >= amount, 'Insufficient balance');
    balanceOf[msg.sender] -= amount;
    balanceOf[to] += amount;
    emit Transfer(msg.sender, to, amount);
    return true;
  }

  function approve(address spender, uint256 amount) external override returns (bool) {
    allowance[msg.sender][spender] = amount;
    emit Approval(msg.sender, spender, amount);
    return true;
  }

  function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
    require(balanceOf[from] >= amount, 'Insufficient balance');
    require(allowance[from][msg.sender] >= amount, 'Insufficient allowance');
    balanceOf[from] -= amount;
    balanceOf[to] += amount;
    allowance[from][msg.sender] -= amount;
    emit Transfer(from, to, amount);
    return true;
  }
}
