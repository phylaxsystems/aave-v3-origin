// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IMockPool} from './IMockPool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';

contract FlashloanPostConditionAssertions is Assertion {
  IMockPool public immutable pool;

  constructor(IMockPool _pool) {
    pool = _pool;
  }

  function triggers() public view override {
    // Register trigger for flashloan function
    registerCallTrigger(this.assertFlashloanRepayment.selector, pool.flashLoanSimple.selector);
  }

  // FLASHLOAN_HSPOST_A: A flashloan succeeds if there's enough balance (amount + fee) transferred back to the protocol
  function assertFlashloanRepayment() external {
    PhEvm.CallInputs[] memory callInputs = ph.getCallInputs(
      address(pool),
      pool.flashLoanSimple.selector
    );
    for (uint256 i = 0; i < callInputs.length; i++) {
      (
        address receiverAddress,
        address asset,
        uint256 amount,
        bytes memory params,
        uint16 referralCode
      ) = abi.decode(callInputs[i].input, (address, address, uint256, bytes, uint16));

      // Get underlying token and aToken
      IERC20 underlying = IERC20(asset);
      address aTokenAddress = pool.getReserveData(asset).aTokenAddress;

      // Get protocol balance before flashloan
      ph.forkPreState();
      uint256 preATokenBalance = underlying.balanceOf(aTokenAddress);

      // Get protocol balance after flashloan
      ph.forkPostState();
      uint256 postATokenBalance = underlying.balanceOf(aTokenAddress);

      uint256 fee = (amount * 5) / 10000; // 0.05% fee
      uint256 totalRequired = amount + fee;

      require(
        postATokenBalance >= totalRequired,
        'Flashloan did not return enough funds to protocol'
      );
    }
  }
}
