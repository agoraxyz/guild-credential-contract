//SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import { IGuildCredential } from "./interfaces/IGuildCredential.sol";
import { LibTransfer } from "./lib/LibTransfer.sol";
import { SoulboundERC721 } from "./token/SoulboundERC721.sol";
import { TreasuryManager } from "./utils/TreasuryManager.sol";
import { OwnableUpgradeable } from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import { Initializable } from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { Base64Upgradeable } from "@openzeppelin/contracts-upgradeable/utils/Base64Upgradeable.sol";
import { ECDSAUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import { StringsUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";

/// @title An NFT representing actions taken by Guild.xyz users.
contract GuildCredential is
    IGuildCredential,
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    SoulboundERC721,
    TreasuryManager
{
    using ECDSAUpgradeable for bytes32;
    using StringsUpgradeable for address;
    using StringsUpgradeable for uint256;
    using LibTransfer for address;
    using LibTransfer for address payable;

    uint256 public constant SIGNATURE_VALIDITY = 1 hours;
    address public validSigner;

    /// @notice Maps the tokenIds to cids (for tokenURIs).
    mapping(uint256 tokenId => string cid) internal cids;

    /// @notice Maps the Guild-related parameters to a tokenId.
    mapping(address holder => mapping(GuildAction action => mapping(uint256 guildId => uint256 tokenId)))
        internal claimedTokens;

    /// @notice Maps the tokenIds to Guild-related parameters.
    mapping(uint256 tokenId => CredentialData credential) internal claimedTokensDetails;

    /// @notice Maps the GuildAction enum to pretty strings for metadata.
    mapping(GuildAction action => CredentialStrings prettyStrings) internal guildActionPrettyNames;

    /// @notice Empty space reserved for future updates.
    uint256[45] private __gap;

    /// @notice Sets metadata and the associated addresses.
    /// @param name The name of the token.
    /// @param symbol The symbol of the token.
    /// @param treasury The address where the collected fees will be sent.
    /// @param _validSigner The address that should sign the parameters for certain functions.
    function initialize(
        string memory name,
        string memory symbol,
        address payable treasury,
        address _validSigner
    ) public initializer {
        validSigner = _validSigner;
        __Ownable_init();
        __UUPSUpgradeable_init();
        __SoulboundERC721_init(name, symbol);
        __TreasuryManager_init(treasury);
    }

    function claim(
        address payToken,
        CredentialDataParams memory credData,
        uint256 signedAt,
        string calldata cid,
        bytes calldata signature
    ) external payable {
        if (signedAt < block.timestamp - SIGNATURE_VALIDITY) revert ExpiredSignature();
        if (claimedTokens[credData.receiver][credData.guildAction][credData.guildId] != 0) revert AlreadyClaimed();
        if (!isValidSignature(credData, signedAt, cid, signature)) revert IncorrectSignature();

        uint256 fee = fee[payToken];
        if (fee == 0) revert IncorrectPayToken(payToken);

        uint256 tokenId = totalSupply() + 1;

        claimedTokens[credData.receiver][credData.guildAction][credData.guildId] = tokenId;
        claimedTokensDetails[tokenId] = CredentialData(
            credData.receiver,
            credData.guildAction,
            uint88(credData.userId),
            credData.guildId,
            credData.guildName,
            uint128(block.timestamp),
            uint128(credData.createdAt)
        );
        cids[tokenId] = cid;

        // Fee collection
        // When there is no msg.value, try transferring ERC20
        // When there is msg.value, ensure it's the correct amount
        if (msg.value == 0) treasury.sendTokenFrom(msg.sender, payToken, fee);
        else if (msg.value != fee) revert IncorrectFee(msg.value, fee);
        else treasury.sendEther(fee);

        _safeMint(credData.receiver, tokenId);

        emit Claimed(credData.receiver, credData.guildAction, credData.guildId);
    }

    function burn(GuildAction guildAction, uint256 guildId) external {
        uint256 tokenId = claimedTokens[msg.sender][guildAction][guildId];

        claimedTokens[msg.sender][guildAction][guildId] = 0;
        delete claimedTokensDetails[tokenId];
        delete cids[tokenId];

        _burn(tokenId);
    }

    function setValidSigner(address newValidSigner) external onlyOwner {
        validSigner = newValidSigner;
        emit ValidSignerChanged(newValidSigner);
    }

    function updateTokenURI(
        CredentialDataParams memory credData,
        uint256 signedAt,
        string calldata newCid,
        bytes calldata signature
    ) external {
        if (signedAt < block.timestamp - SIGNATURE_VALIDITY) revert ExpiredSignature();
        if (!isValidSignature(credData, signedAt, newCid, signature)) revert IncorrectSignature();

        uint256 tokenId = claimedTokens[credData.receiver][credData.guildAction][credData.guildId];
        if (tokenId == 0) revert NonExistentToken(tokenId);

        cids[tokenId] = newCid;

        emit TokenURIUpdated(tokenId);
    }

    function setCredentialStrings(
        GuildAction guildAction,
        CredentialStrings memory credentialStrings
    ) public onlyOwner {
        guildActionPrettyNames[guildAction] = credentialStrings;
        emit CredentialStringsSet(guildAction);
    }

    function hasClaimed(address account, GuildAction guildAction, uint256 id) external view returns (bool claimed) {
        return claimedTokens[account][guildAction][id] != 0;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_exists(tokenId)) revert NonExistentToken(tokenId);

        CredentialData memory credential = claimedTokensDetails[tokenId];

        // solhint-disable quotes
        string memory json = Base64Upgradeable.encode(
            bytes(
                string.concat(
                    '{"name": "',
                    guildActionPrettyNames[credential.action].actionName,
                    " ",
                    credential.guildName,
                    '", "description": "',
                    guildActionPrettyNames[credential.action].description,
                    " ",
                    credential.guildName,
                    ' on Guild.xyz.", "image": "ipfs://',
                    cids[tokenId],
                    '", "attributes": [ { "trait_type": "type", "value": "',
                    guildActionPrettyNames[credential.action].actionName,
                    '"}, { "trait_type": "guildId",',
                    ' "value": "',
                    credential.id.toString(),
                    '" }, { "trait_type": "userId", "value": "',
                    uint256(credential.userId).toString(),
                    '" }, { "trait_type": "mintDate", "display_type": "date", "value": ',
                    uint256(credential.mintDate).toString(),
                    ' }, { "trait_type": "actionDate",',
                    ' "display_type": "date",',
                    ' "value": ',
                    uint256(credential.createdAt).toString(),
                    " }",
                    " ] }"
                )
            )
        );
        // solhint-enable quotes

        return string.concat("data:application/json;base64,", json);
    }

    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Checks the validity of the signature for the given params.
    function isValidSignature(
        CredentialDataParams memory credData,
        uint256 signedAt,
        string calldata cid,
        bytes calldata signature
    ) internal view returns (bool) {
        if (signature.length != 65) revert IncorrectSignature();
        bytes32 message = keccak256(
            abi.encode(
                credData.receiver,
                credData.guildAction,
                credData.userId,
                credData.guildId,
                credData.guildName,
                credData.createdAt,
                signedAt,
                cid
            )
        ).toEthSignedMessageHash();
        return message.recover(signature) == validSigner;
    }
}
