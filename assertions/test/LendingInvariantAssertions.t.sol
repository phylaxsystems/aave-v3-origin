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
import {LendingInvariantAssertions} from '../src/showcase/LendingInvariantAssertions.a.sol';
import {IMockL2Pool} from '../src/interfaces/IMockL2Pool.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';
import {L2Encoder} from '../../src/contracts/helpers/L2Encoder.sol';

contract TestLendingInvariantAssertions is CredibleTest, Test, TestnetProcedures {
  IMockL2Pool public pool;
  LendingInvariantAssertions public assertions;
  L2Encoder public l2Encoder;
  address public user;
  address public asset;
  IERC20 public underlying;
  string public constant ASSERTION_LABEL = 'LendingInvariantAssertions';

  function setUp() public {
    // Initialize test environment with real contracts (L2 enabled for L2Encoder)
    initL2TestEnvironment();

    // Set up user and get pool reference
    user = alice;
    pool = IMockL2Pool(report.poolProxy);
    asset = tokenList.usdx;
    underlying = IERC20(asset);

    // Set up L2Encoder for creating compact parameters
    l2Encoder = L2Encoder(report.l2Encoder);

    // Deploy assertions contract with IMockL2Pool
    assertions = new LendingInvariantAssertions();

    // Mint tokens to the test contract and transfer to user
    deal(asset, address(this), 1000e6);
    underlying.transfer(user, 1000e6);
  }

  function testAssertionDepositBalanceChanges() public {
    uint256 depositAmount = 100e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LendingInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Set user as the caller and ensure enough allowance
    vm.startPrank(user);
    underlying.approve(address(pool), depositAmount);

    // Create L2Pool compact parameters
    bytes32 encodedInput = l2Encoder.encodeSupplyParams(asset, depositAmount, 0);

    // This should pass because the real protocol correctly handles deposits
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, encodedInput)
    );
    vm.stopPrank();
  }

  function testAssertionWithdrawBalanceChanges() public {
    uint256 depositAmount = 100e6;
    uint256 withdrawAmount = 50e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LendingInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Set user as the caller and ensure enough allowance
    vm.startPrank(user);
    underlying.approve(address(pool), depositAmount);

    // First deposit some tokens using L2Pool
    bytes32 depositEncodedInput = l2Encoder.encodeSupplyParams(asset, depositAmount, 0);
    pool.supply(depositEncodedInput);

    // Then withdraw some tokens using L2Pool
    bytes32 withdrawEncodedInput = l2Encoder.encodeWithdrawParams(asset, withdrawAmount);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.withdraw.selector, withdrawEncodedInput)
    );
    vm.stopPrank();
  }

  function testAssertionBatchDepositBalanceChanges() public {
    uint256 totalDeposit = 10e6 + 20e6 + 15e6 + 5e6 + 50e6;

    // Deploy the batch depositor contract
    BatchDepositor batcher = new BatchDepositor(address(pool), asset, user, l2Encoder);

    // Mint tokens to the batcher contract
    deal(asset, address(batcher), totalDeposit);

    // Approve the pool from the batcher contract
    vm.prank(address(batcher));
    IERC20(asset).approve(address(pool), totalDeposit);

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LendingInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    vm.prank(user);
    // Validate the assertion by calling the batcher (which triggers fallback)
    cl.validate(
      ASSERTION_LABEL,
      address(batcher),
      0,
      '' // fallback, so empty calldata
    );
  }

  function testDepositBalanceChangesDirectly() public {
    uint256 depositAmount = 100e6;

    // Get the aToken address for the asset
    address aTokenAddress = pool.getReserveData(asset).aTokenAddress;
    IERC20 aToken = IERC20(aTokenAddress);

    // Set user as the caller and ensure enough allowance
    vm.startPrank(user);
    underlying.approve(address(pool), depositAmount);

    // Record balances before
    uint256 userBalanceBefore = underlying.balanceOf(user);
    uint256 aTokenBalanceBefore = aToken.balanceOf(user);

    // Perform the deposit using L2Pool
    bytes32 encodedInput = l2Encoder.encodeSupplyParams(asset, depositAmount, 0);
    pool.supply(encodedInput);

    // Record balances after
    uint256 userBalanceAfter = underlying.balanceOf(user);
    uint256 aTokenBalanceAfter = aToken.balanceOf(user);

    vm.stopPrank();

    // Check user balance decreased by deposit amount
    assertEq(
      userBalanceBefore - userBalanceAfter,
      depositAmount,
      'User balance did not decrease by deposit amount'
    );

    // Assert the user's aToken balance increased by depositAmount
    assertEq(
      aTokenBalanceAfter - aTokenBalanceBefore,
      depositAmount,
      'aToken balance did not increase by deposit amount'
    );
  }

  function testWithdrawBalanceChangesDirectly() public {
    uint256 depositAmount = 100e6;
    uint256 withdrawAmount = 50e6;

    // Get the aToken address for the asset
    address aTokenAddress = pool.getReserveData(asset).aTokenAddress;
    IERC20 aToken = IERC20(aTokenAddress);

    // Set user as the caller and ensure enough allowance
    vm.startPrank(user);
    underlying.approve(address(pool), depositAmount);

    // First deposit some tokens using L2Pool
    bytes32 depositEncodedInput = l2Encoder.encodeSupplyParams(asset, depositAmount, 0);
    pool.supply(depositEncodedInput);

    // Record balances before withdraw
    uint256 userBalanceBefore = underlying.balanceOf(user);
    uint256 aTokenBalanceBefore = aToken.balanceOf(user);

    // Then withdraw some tokens using L2Pool
    bytes32 withdrawEncodedInput = l2Encoder.encodeWithdrawParams(asset, withdrawAmount);
    pool.withdraw(withdrawEncodedInput);

    // Record balances after withdraw
    uint256 userBalanceAfter = underlying.balanceOf(user);
    uint256 aTokenBalanceAfter = aToken.balanceOf(user);

    vm.stopPrank();

    // Check user balance increased by withdraw amount
    assertEq(
      userBalanceAfter - userBalanceBefore,
      withdrawAmount,
      'User balance did not increase by withdraw amount'
    );

    // Check aToken balance decreased by withdraw amount
    assertEq(
      aTokenBalanceBefore - aTokenBalanceAfter,
      withdrawAmount,
      'aToken balance did not decrease by withdraw amount'
    );
  }
}

contract BatchDepositor {
  IMockL2Pool public pool;
  address public asset;
  address public user;
  L2Encoder public l2Encoder;

  constructor(address pool_, address asset_, address user_, L2Encoder l2Encoder_) {
    pool = IMockL2Pool(pool_);
    asset = asset_;
    user = user_;
    l2Encoder = l2Encoder_;
  }

  // Fallback to perform a batch of deposits using L2Pool
  fallback() external {
    bytes32 encodedInput1 = l2Encoder.encodeSupplyParams(asset, 10e6, 0);
    pool.supply(encodedInput1);
    //bytes32 encodedInput2 = l2Encoder.encodeSupplyParams(asset, 20e6, 0);
    //pool.supply(encodedInput2);
    // bytes32 encodedInput3 = l2Encoder.encodeSupplyParams(asset, 15e6, 0);
    // pool.supply(encodedInput3);
    // bytes32 encodedInput4 = l2Encoder.encodeSupplyParams(asset, 5e6, 0);
    // pool.supply(encodedInput4);
    // bytes32 encodedInput5 = l2Encoder.encodeSupplyParams(asset, 50e6, 0);
    // pool.supply(encodedInput5);
  }
}
