// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommitRevealBounty} from "./CommitRevealBounty.sol";

/// @title RitualCommitRevealBounty
/// @notice Ritual Chain deployment of the commit-reveal bounty. It overrides
///         the `_runJudge` hook to perform batch AI judging through the LLM
///         inference precompile (0x0802) inside a TEE executor.
///
/// @dev    The commit-reveal lifecycle is inherited unchanged from
///         `CommitRevealBounty`. Only the judging step is Ritual-specific.
///
///         `llmInput` is the full 30-field LLM request, ABI-encoded off-chain
///         (see the ritual-dapp-llm skill). It must contain ALL revealed
///         answers in a single `messagesJson` payload so the model judges the
///         whole batch in one inference call — not one call per answer.
///
///         Advanced (hidden submissions) variant: instead of revealing
///         plaintext on-chain, participants encrypt answers to the executor
///         public key (ECIES) and pass them via `encryptedSecrets`. The TEE
///         decrypts them inside the enclave, judges them, and only the verdict
///         leaves the enclave. See ARCHITECTURE.md for the full data-flow note.
contract RitualCommitRevealBounty is CommitRevealBounty {
    /// @dev Short-running async LLM inference precompile.
    address internal constant LLM_INFERENCE_PRECOMPILE = address(0x0802);

    /// @dev Response envelope conversation-history tuple, decoded but unused.
    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    /// @notice Calls the LLM precompile with the pre-encoded batch request and
    ///         returns the decoded completion bytes for on-chain storage.
    function _runJudge(
        uint256 /* bountyId */,
        bytes calldata llmInput
    ) internal override returns (bytes memory) {
        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        // Always check has_error before trusting completionData.
        require(!hasError, errorMessage);

        return completionData;
    }

    /// @dev Short-running async precompiles (HTTP/LLM/DKMS) wrap their result
    ///      as abi.encode(bytes simmedInput, bytes actualOutput). Unwrap to the
    ///      actual output. Reverts bubble up the raw revert data.
    function _executePrecompile(
        address precompile,
        bytes calldata input
    ) internal returns (bytes memory) {
        (bool success, bytes memory rawOutput) = precompile.call(input);

        if (!success) {
            assembly {
                revert(add(rawOutput, 32), mload(rawOutput))
            }
        }

        (, bytes memory actualOutput) = abi.decode(rawOutput, (bytes, bytes));
        return actualOutput;
    }
}
