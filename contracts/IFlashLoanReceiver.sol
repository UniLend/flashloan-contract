pragma solidity ^0.6.2;

/**
* @title IFlashLoanReceiver interface
* @notice Interface for the Unilend fee IFlashLoanReceiver.
* @dev implement this interface to develop a flashloan-compatible flashLoanReceiver contract
**/
interface IFlashLoanReceiver {
    function executeOperation(address _reserve, uint256 _amount, uint256 _fee, bytes calldata _params) external;
}