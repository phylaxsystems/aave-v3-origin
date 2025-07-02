// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title MockedBorrowingInvariantAssertions Tests
 * @notice This test file uses a mocked version of the Aave V3 protocol to verify that
 *         our assertions correctly revert when the protocol violates our invariants.
 *         It ensures that our assertions actually catch and prevent invalid state
 *         changes.
 *
 *         For example, it verifies that the repay debt changes assertion reverts when
 *         a user repays assets but the protocol fails to decrease their debt,
 *         catching potential bugs in the protocol's implementation.
 *
 *         The mock pool is located in assertions/mocks/BrokenPool.sol
 */
import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {BorrowingInvariantAssertions} from '../src/BorrowingInvariantAssertions.a.sol';
import {IMockL2Pool} from '../src/IMockL2Pool.sol';
import {BrokenPool} from '../mocks/BrokenPool.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {L2Encoder} from '../../src/contracts/helpers/L2Encoder.sol';
import {IPool} from '../../src/contracts/interfaces/IPool.sol';

contract MockedBorrowingInvariantAssertionsTest is CredibleTest, Test {
  IMockL2Pool public pool;
  BorrowingInvariantAssertions public assertions;
  L2Encoder public l2Encoder;
  address public user;
  address public asset;
  IERC20 public underlying;
  string public constant ASSERTION_LABEL = 'BorrowingInvariantAssertions';

  function setUp() public {
    // Deploy mock pool
    pool = IMockL2Pool(address(new BrokenPool()));

    // Deploy assertions (no constructor arguments needed now)
    assertions = new BorrowingInvariantAssertions();

    // Set up user and asset
    user = address(0x1);
    asset = address(0x2);
    underlying = IERC20(asset);

    // Set up L2Encoder for creating compact parameters
    l2Encoder = new L2Encoder(IPool(address(pool)));

    // Set up user with debt
    BrokenPool(address(pool)).setUserDebt(user, 1000e6);

    // Configure mock to break repay debt changes
    BrokenPool(address(pool)).setBreakRepayDebt(true);
  }

  function testAssertionLiabilityDecreaseFailure() public {
    uint256 repayAmount = 100e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BorrowingInvariantAssertions).creationCode,
      abi.encode(IMockL2Pool(address(pool)))
    );

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for repay
    bytes32 repayArgs = l2Encoder.encodeRepayParams(asset, repayAmount, 2);

    // This should revert because the mock pool doesn't decrease debt
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(IMockL2Pool.repay.selector, repayArgs)
    );
    vm.stopPrank();
  }

  function testAssertionUnhealthyBorrowPreventionFailure() public {
    // Set up an unhealthy user (health factor < 1e18)
    BrokenPool(address(pool)).setUserDebt(user, 1000e6); // High debt to make user unhealthy

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BorrowingInvariantAssertions).creationCode,
      abi.encode(IMockL2Pool(address(pool)))
    );

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 100e6, 2, 0);

    // This should revert because the mock pool allows unhealthy users to borrow
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(IMockL2Pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }
}
