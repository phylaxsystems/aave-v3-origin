// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {Test} from 'forge-std/Test.sol';
import {console} from 'forge-std/console.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {MinimalPhEvmBug} from '../src/production/MinimalPhEvmBug.a.sol';
import {IMockL2Pool} from '../src/interfaces/IMockL2Pool.sol';
import {L2Encoder} from '../../src/contracts/helpers/L2Encoder.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';

/**
 * @title MinimalPhEvmBugTest
 * @notice Minimal test to reproduce PhEvm double-call issue
 * @dev This test demonstrates that ph.getCallInputs() reports 2 calls when only 1 is made
 */
contract MinimalPhEvmBugTest is CredibleTest, TestnetProcedures {
  MinimalPhEvmBug assertion;
  IMockL2Pool pool;
  IERC20 underlying;
  address asset;
  address user;
  L2Encoder l2Encoder;

  string constant ASSERTION_LABEL = 'MinimalPhEvmBug';
  string constant BREAKDOWN_LABEL = 'MinimalPhEvmBugBreakdown';

  function setUp() public {
    // Set up test environment using L2TestEnvironment (like DebtSumInvariant)
    initL2TestEnvironment();

    // Get the pool and asset from the deployed contracts
    pool = IMockL2Pool(report.poolProxy);
    asset = tokenList.usdx; // Use USDX as the test asset
    underlying = IERC20(asset);
    user = alice;

    // Use the L2Encoder from the report (like DebtSumInvariant)
    l2Encoder = L2Encoder(report.l2Encoder);

    // Deploy the minimal assertion
    assertion = new MinimalPhEvmBug(pool, asset);
  }

  function test_DebugSelector() public {
    // Debug: Print the actual selector being used
    bytes4 actualSelector = pool.borrow.selector;
    bytes4 expectedSelector = bytes4(keccak256('borrow(bytes32)'));

    // Check if they match
    require(actualSelector == expectedSelector, 'Selectors do not match');
  }

  function test_ManualBorrowCheck() public {
    // Manual test that performs the same operations as the assertion test
    // but without using the assertion system to verify the protocol works correctly

    // Set up fresh user with collateral (same as assertion test)
    deal(asset, user, 20000e6);
    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral first (same as assertion test)
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    pool.supply(supplyArgs);

    // Get debt token for verification
    address variableDebtToken = pool.getReserveData(asset).variableDebtTokenAddress;
    IERC20 debtToken = IERC20(variableDebtToken);

    // Check state before borrow
    uint256 debtSupplyBefore = debtToken.totalSupply();
    uint256 userBalanceBefore = underlying.balanceOf(user);

    console.log('=== BEFORE BORROW ===');
    console.log('User address:');
    console.logAddress(user);
    console.log('Asset address:');
    console.logAddress(asset);
    console.log('Debt token address:');
    console.logAddress(variableDebtToken);
    console.log('Debt token total supply:');
    console.log(debtSupplyBefore);
    console.log('User underlying balance:');
    console.log(userBalanceBefore);
    console.log('Borrow amount to be requested:');
    console.log(uint256(1000e6));

    // Make exactly 1 borrow call (same as assertion test)
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 1000e6, 2, 0);
    console.log('Borrow args (encoded):');
    console.logBytes32(borrowArgs);

    console.log('=== EXECUTING BORROW ===');
    pool.borrow(borrowArgs);
    console.log('Borrow executed successfully');

    // Check state after borrow
    uint256 debtSupplyAfter = debtToken.totalSupply();
    uint256 userBalanceAfter = underlying.balanceOf(user);

    // Verify the protocol worked correctly
    uint256 debtIncrease = debtSupplyAfter - debtSupplyBefore;
    uint256 userBalanceIncrease = userBalanceAfter - userBalanceBefore;

    console.log('=== AFTER BORROW ===');
    console.log('Debt token total supply:');
    console.log(debtSupplyAfter);
    console.log('User underlying balance:');
    console.log(userBalanceAfter);
    console.log('Debt token supply increase:');
    console.log(debtIncrease);
    console.log('User balance increase:');
    console.log(userBalanceIncrease);
    console.log('Expected increase:');
    console.log(uint256(1000e6));

    // These should match the borrowed amount
    assertEq(debtIncrease, 1000e6, 'Debt token supply should increase by borrowed amount');
    assertEq(userBalanceIncrease, 1000e6, 'User should receive exactly the borrowed amount');
    assertEq(debtIncrease, userBalanceIncrease, 'Debt increase should equal user balance increase');

    console.log('=== VERIFICATION ===');
    console.log('Debt increase matches expected:');
    console.log(debtIncrease == 1000e6);
    console.log('User balance increase matches expected:');
    console.log(userBalanceIncrease == 1000e6);
    console.log('Debt increase equals user balance increase:');
    console.log(debtIncrease == userBalanceIncrease);
    console.log('Protocol behavior is correct - single borrow call worked as expected');

    vm.stopPrank();
  }

  function test_PhEvmDoubleCallIssue() public {
    // Add assertion to the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(MinimalPhEvmBug).creationCode,
      abi.encode(address(pool), asset)
    );

    // This test demonstrates the bug:
    // 1. We make exactly 1 borrow call
    // 2. The assertion expects exactly 1 borrow call
    // 3. But PhEvm reports 2 calls, causing the assertion to fail

    // Set up fresh user with collateral (like in BaseInvariants.t.sol)
    deal(asset, user, 20000e6);
    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral first
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    pool.supply(supplyArgs);

    // Make exactly 1 borrow call
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 1000e6, 2, 0);

    // This should pass since we only made 1 borrow call
    // But it fails because PhEvm reports 2 calls
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );

    vm.stopPrank();
  }
}
