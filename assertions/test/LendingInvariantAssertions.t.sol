// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title LendingInvariantAssertions Tests
 * @notice This test file uses the real Aave V3 protocol to verify that our assertions
 *         correctly pass when the protocol behaves as expected. It ensures that our
 *         assertions don't revert when they shouldn't, validating that our invariant
 *         checks are not overly restrictive.
 *
 *         For example, it verifies that the deposit balance changes assertion passes when
 *         a user successfully deposits assets, as the real protocol correctly handles
 *         the token transfers and balance updates.
 */
import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {LendingPostConditionAssertions} from '../src/LendingInvariantAssertions.a.sol';
import {IMockPool} from '../src/IMockPool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';

contract TestLendingInvariantAssertions is CredibleTest, Test, TestnetProcedures {
  IMockPool public pool;
  LendingPostConditionAssertions public assertions;
  address public user;
  address public asset;
  IERC20 public underlying;
  string constant ASSERTION_LABEL = 'LendingInvariantAssertions';

  function setUp() public {
    // Initialize test environment with real contracts
    initTestEnvironment();

    // Set up user and get pool reference
    user = alice;
    pool = IMockPool(report.poolProxy);
    asset = tokenList.usdx;
    underlying = IERC20(asset);

    // Deploy assertions contract
    assertions = new LendingPostConditionAssertions(pool);

    // Mint tokens to the test contract and transfer to user
    deal(asset, address(this), 1000e6);
    underlying.transfer(user, 1000e6);
  }

  function test_assertionDepositBalanceChanges() public {
    uint256 depositAmount = 100e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LendingPostConditionAssertions).creationCode,
      abi.encode(pool)
    );

    // Set user as the caller and ensure enough allowance
    vm.startPrank(user);
    underlying.approve(address(pool), depositAmount);

    // This should pass because the real protocol correctly handles deposits
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, asset, depositAmount, user, 0)
    );
    vm.stopPrank();
  }

  function test_assertionWithdrawBalanceChanges() public {
    uint256 depositAmount = 100e6;
    uint256 withdrawAmount = 50e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LendingPostConditionAssertions).creationCode,
      abi.encode(pool)
    );

    // Set user as the caller and ensure enough allowance
    vm.startPrank(user);
    underlying.approve(address(pool), depositAmount);

    // First deposit some tokens (direct call since we're not testing deposit)
    pool.supply(asset, depositAmount, user, 0);

    // Then withdraw some tokens
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.withdraw.selector, asset, withdrawAmount, user)
    );
    vm.stopPrank();
  }
}
