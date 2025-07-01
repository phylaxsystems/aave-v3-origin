// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Assertion} from 'credible-std/Assertion.sol';
import {PhEvm} from 'credible-std/PhEvm.sol';
import {IMockL2Pool} from './IMockL2Pool.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';

contract FlashloanPostConditionAssertions is Assertion {
  IMockL2Pool public pool;

  constructor(IMockL2Pool _pool) {
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
      // Decode L2Pool flashLoanSimple parameters: receiverAddress (20 bytes) + asset (20 bytes) + amount (32 bytes) + params (variable) + referralCode (2 bytes)
      // Note: flashLoanSimple still uses the old format since it's not part of the compact L2Pool interface
      (, address asset, uint256 amount, , ) = abi.decode(
        callInputs[i].input,
        (address, address, uint256, bytes, uint16)
      );

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
      uint256 totalRequired = preATokenBalance + fee;

      require(
        postATokenBalance >= totalRequired,
        'Flashloan did not return enough funds to protocol'
      );
    }
  }
}
