// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {Test} from 'forge-std/Test.sol';
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
    require(actualSelector == expectedSelector, "Selectors don't match!");
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
