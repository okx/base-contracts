// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "./IDisburser.sol";

/**
 * @title PlatformFeeDisburser
 * @dev Reference disburser that takes a platform fee + an evaluator fee in
 *      basis points and forwards the remainder to the job's provider.
 *
 *      Settles synchronously via IDisburser.onSettlement: when the singleton
 *      transfers funds here on complete/settle, this contract is called with
 *      full context, splits the amount three ways, and forwards in the same
 *      transaction.
 *
 *      Fee config is immutable. Spin up a new disburser per fee tier.
 *
 *      The singleton is the only authorized caller of onSettlement. Any
 *      other caller reverts with NotSingleton.
 */
contract PlatformFeeDisburser is IDisburser {
    using SafeERC20 for IERC20;

    address public immutable singleton;
    address public immutable treasury;
    uint256 public immutable platformFeeBP;
    uint256 public immutable evaluatorFeeBP;

    event Disbursed(
        uint256 indexed jobId,
        address indexed token,
        address indexed provider,
        address evaluator,
        uint256 platformFee,
        uint256 evaluatorFee,
        uint256 providerNet
    );

    error FeeTooHigh();
    error NotSingleton();
    error ZeroAddress();

    constructor(
        address _singleton,
        address _treasury,
        uint256 _platformFeeBP,
        uint256 _evaluatorFeeBP
    ) {
        if (_singleton == address(0) || _treasury == address(0)) revert ZeroAddress();
        if (_platformFeeBP + _evaluatorFeeBP > 10000) revert FeeTooHigh();
        singleton = _singleton;
        treasury = _treasury;
        platformFeeBP = _platformFeeBP;
        evaluatorFeeBP = _evaluatorFeeBP;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == type(IDisburser).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IDisburser
    function onSettlement(
        uint256 jobId,
        address token,
        uint256 amount,
        address /*client*/,
        address provider,
        address evaluator,
        bytes calldata /*optParams*/
    ) external returns (bytes4) {
        if (msg.sender != singleton) revert NotSingleton();

        uint256 platformFee = (amount * platformFeeBP) / 10000;
        uint256 evaluatorFee = (amount * evaluatorFeeBP) / 10000;
        uint256 providerNet = amount - platformFee - evaluatorFee;

        IERC20 t = IERC20(token);
        if (platformFee > 0) {
            t.safeTransfer(treasury, platformFee);
        }
        if (evaluatorFee > 0) {
            t.safeTransfer(evaluator, evaluatorFee);
        }
        if (providerNet > 0) {
            t.safeTransfer(provider, providerNet);
        }

        emit Disbursed(
            jobId,
            token,
            provider,
            evaluator,
            platformFee,
            evaluatorFee,
            providerNet
        );

        return IDisburser.onSettlement.selector;
    }
}
