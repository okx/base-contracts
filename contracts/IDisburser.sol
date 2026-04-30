// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title IDisburser
 * @dev Optional interface for disburser contracts attached to ERC-8183 jobs.
 *      A disburser opts in to synchronous settlement callbacks by supporting
 *      this interface via ERC-165. Passive receivers (EOAs, Safes, splitters)
 *      do not implement this and the singleton will simply transfer tokens
 *      and skip the callback.
 *
 *      Data flow: when complete/settle ships funds to a disburser that opts
 *      in, the singleton calls onSettlement with full context atomically:
 *
 *          singleton ─┬─ safeTransfer(disburser, amount)
 *                     └─ disburser.onSettlement(...)  // disburser routes funds
 *
 *      The disburser MUST return IDisburser.onSettlement.selector to confirm
 *      the call. Returning anything else, or reverting, rolls back the
 *      entire settlement transaction.
 */
interface IDisburser is IERC165 {
    /// @notice Called by the singleton after settlement funds are transferred.
    /// @param jobId      Job identifier
    /// @param token      ERC-20 payment token
    /// @param amount     Amount just transferred (now in disburser's balance)
    /// @param client     Job client (for context / authorization)
    /// @param provider   Job provider
    /// @param evaluator  Job evaluator
    /// @param optParams  Arbitrary bytes passed from complete/settle caller
    /// @return magic     Must equal IDisburser.onSettlement.selector
    function onSettlement(
        uint256 jobId,
        address token,
        uint256 amount,
        address client,
        address provider,
        address evaluator,
        bytes calldata optParams
    ) external returns (bytes4 magic);
}
