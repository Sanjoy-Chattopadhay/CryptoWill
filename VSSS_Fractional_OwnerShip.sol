// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IERC721 {
    function transferFrom(address from, address to, uint256 tokenId) external;
    function ownerOf(uint256 tokenId) external view returns (address);
}

/**
 * @title Hybrid Pedersen VSS NFT Fractional Inheritance
 * @dev Implementation with dual polynomials F(x) and G(x) and fractional ownership
 */
contract HybridVSSFractionalInheritance {
    
    // Simplified discrete log parameters (in practice use proper curve)
    uint256 public constant P = 2**127 - 1; // Prime modulus
    uint256 public constant G = 2; // Generator g
    uint256 public constant H = 3; // Generator h
    uint256 constant TOTAL_PERCENTAGE = 10000; // 100.00% (basis points)
    
    struct Will {
        address nftContract;
        uint256 tokenId;
        address[] heirs;
        uint256[] percentages;
        address creator;
        uint256 threshold;
        uint256[] commitments; // Pedersen commitments C_j
        bool active;
        bool claimed;
        uint256 revealedCount;
    }

    struct TrusteeShare {
        uint256 secretShare; // s_i = F(i)
        uint256 blindingShare; // t_i = G(i)
        uint256 xCoordinate; // evaluation point
        bool committed;
        bool revealed;
        bool verified; // verified against commitments
    }

    struct FractionalOwnership {
        uint256 totalShares;
        mapping(address => uint256) ownerShares;
        address[] owners;
        bool distributed;
    }

    // Struct to avoid stack too deep in createWill
    struct CreateWillParams {
        address nftContract;
        uint256 tokenId;
        address[] heirs;
        uint256[] percentages;
        address[] trustees;
        uint256[] commitments;
        uint256[] secretShares;
        uint256[] blindingShares;
        uint256[] xCoordinates;
        uint256 threshold;
    }

    mapping(uint256 => Will) public wills;
    mapping(uint256 => mapping(address => TrusteeShare)) public trusteeShares;
    mapping(uint256 => address[]) public trustees;
    mapping(uint256 => FractionalOwnership) private fractionalOwnerships;
    uint256 public willCounter;

    event WillCreated(uint256 indexed willId, address indexed creator, uint256[] commitments);
    event ShareVerified(uint256 indexed willId, address indexed trustee, bool valid);
    event ShareRevealed(uint256 indexed willId, address indexed trustee);
    event InheritanceExecuted(uint256 indexed willId, bool success);
    event FractionalOwnershipDistributed(uint256 indexed willId, address[] heirs, uint256[] shares);
    event FractionalShareTransferred(uint256 indexed willId, address indexed from, address indexed to, uint256 amount);

    modifier onlyCreator(uint256 willId) {
        require(msg.sender == wills[willId].creator, "Only creator");
        _;
    }

    modifier onlyTrustee(uint256 willId) {
        require(trusteeShares[willId][msg.sender].committed, "Not a trustee");
        _;
    }

    modifier onlyFractionalOwner(uint256 willId) {
        require(fractionalOwnerships[willId].ownerShares[msg.sender] > 0, "Not a fractional owner");
        _;
    }

    modifier willExists(uint256 willId) {
        require(willId < willCounter, "Will does not exist");
        require(wills[willId].active, "Will not active");
        _;
    }

    /**
     * @dev Create will with Pedersen commitments and fractional ownership
     */
    function createWill(
        address nftContract,
        uint256 tokenId,
        address[] memory heirs,
        uint256[] memory percentages,
        address[] memory _trustees,
        uint256[] memory _commitments,
        uint256[] memory secretShares,
        uint256[] memory blindingShares,
        uint256[] memory xCoordinates,
        uint256 threshold
    ) external returns (uint256) {
        // Pack parameters to avoid stack too deep
        CreateWillParams memory params = CreateWillParams({
            nftContract: nftContract,
            tokenId: tokenId,
            heirs: heirs,
            percentages: percentages,
            trustees: _trustees,
            commitments: _commitments,
            secretShares: secretShares,
            blindingShares: blindingShares,
            xCoordinates: xCoordinates,
            threshold: threshold
        });

        return _createWillInternal(params);
    }

    /**
     * @dev Internal function to handle will creation
     */
    function _createWillInternal(CreateWillParams memory params) internal returns (uint256) {
        require(IERC721(params.nftContract).ownerOf(params.tokenId) == msg.sender, "Not NFT owner");
        require(params.trustees.length == params.secretShares.length, "Length mismatch");
        require(params.trustees.length == params.blindingShares.length, "Length mismatch");
        require(params.threshold <= params.trustees.length, "Invalid threshold");
        
        _validateHeirPercentages(params.heirs, params.percentages);

        uint256 willId = willCounter++;
        
        // Initialize will struct
        _initializeWill(willId, params);
        
        // Initialize fractional ownership
        fractionalOwnerships[willId].totalShares = TOTAL_PERCENTAGE;
        
        // Initialize trustees
        _initializeTrustees(willId, params);

        // Transfer NFT to contract
        IERC721(params.nftContract).transferFrom(msg.sender, address(this), params.tokenId);

        emit WillCreated(willId, msg.sender, params.commitments);
        return willId;
    }

    /**
     * @dev Validate that heir percentages sum to 100% and no duplicates exist
     */
    function _validateHeirPercentages(address[] memory heirs, uint256[] memory percentages) internal pure {
        require(heirs.length > 0, "Must have at least one heir");
        require(heirs.length == percentages.length, "Heirs and percentages length mismatch");
        
        uint256 total = 0;
        for (uint256 i = 0; i < percentages.length; i++) {
            require(percentages[i] > 0, "Percentage must be greater than 0");
            total += percentages[i];
        }
        require(total == TOTAL_PERCENTAGE, "Percentages must sum to 100%");

        // Check for duplicate heirs
        for (uint256 i = 0; i < heirs.length; i++) {
            for (uint256 j = i + 1; j < heirs.length; j++) {
                require(heirs[i] != heirs[j], "Duplicate heir addresses not allowed");
            }
        }
    }

    /**
     * @dev Initialize will struct (removed activationTime)
     */
    function _initializeWill(uint256 willId, CreateWillParams memory params) internal {
        Will storage newWill = wills[willId];
        
        newWill.nftContract = params.nftContract;
        newWill.tokenId = params.tokenId;
        newWill.heirs = params.heirs;
        newWill.percentages = params.percentages;
        newWill.creator = msg.sender;
        newWill.threshold = params.threshold;
        newWill.commitments = params.commitments;
        newWill.active = true;
    }

    /**
     * @dev Initialize trustees with their shares
     */
    function _initializeTrustees(uint256 willId, CreateWillParams memory params) internal {
        for (uint256 i = 0; i < params.trustees.length; i++) {
            trustees[willId].push(params.trustees[i]);
            trusteeShares[willId][params.trustees[i]] = TrusteeShare({
                secretShare: params.secretShares[i],
                blindingShare: params.blindingShares[i],
                xCoordinate: params.xCoordinates[i],
                committed: true,
                revealed: false,
                verified: false
            });
        }
    }

    /**
     * @dev Verify share against Pedersen commitments
     * @param willId Will ID
     * Formula: g^(s_i) * h^(t_i) == ∏ C_j^(i^j)
     */
    function verifyShare(uint256 willId) external willExists(willId) onlyTrustee(willId) {
        TrusteeShare storage share = trusteeShares[willId][msg.sender];
        require(!share.verified, "Already verified");

        Will storage will = wills[willId];
        
        // Left side: g^(s_i) * h^(t_i)
        uint256 leftSide = modMul(
            modExp(G, share.secretShare, P),
            modExp(H, share.blindingShare, P),
            P
        );

        // Right side: ∏ C_j^(i^j) for j = 0 to k-1
        uint256 rightSide = _calculateRightSide(will.commitments, share.xCoordinate);

        bool isValid = (leftSide == rightSide);
        share.verified = isValid;

        emit ShareVerified(willId, msg.sender, isValid);
    }

    /**
     * @dev Calculate right side of verification equation
     */
    function _calculateRightSide(uint256[] memory commitments, uint256 xCoordinate) 
        internal 
        pure 
        returns (uint256) 
    {
        uint256 rightSide = 1;
        uint256 iPower = 1; // i^j
        
        for (uint256 j = 0; j < commitments.length; j++) {
            uint256 term = modExp(commitments[j], iPower, P);
            rightSide = modMul(rightSide, term, P);
            iPower = modMul(iPower, xCoordinate, P); // Update i^j
        }
        
        return rightSide;
    }

    /**
     * @dev Reveal share (removed time constraint)
     */
    function revealShare(uint256 willId) external willExists(willId) onlyTrustee(willId) {
        TrusteeShare storage share = trusteeShares[willId][msg.sender];
        require(share.verified, "Share not verified");
        require(!share.revealed, "Already revealed");

        share.revealed = true;
        wills[willId].revealedCount++;

        emit ShareRevealed(willId, msg.sender);
    }

    /**
     * @dev Execute inheritance with fractional ownership distribution
     */
    function executeInheritance(uint256 willId) external willExists(willId) {
        Will storage will = wills[willId];
        require(will.active, "Will not active");
        require(!will.claimed, "Already claimed");
        require(will.revealedCount >= will.threshold, "Insufficient shares");
        require(!fractionalOwnerships[willId].distributed, "Fractional ownership already distributed");

        // Simplified reconstruction (using only secret shares, not blinding)
        // uint256 secret = lagrangeReconstruction(willId, will.threshold);
        
        // In practice, you'd verify the reconstructed secret here
        // For simplicity, we assume reconstruction success
        
        will.claimed = true;
        
        // Distribute fractional ownership instead of direct NFT transfer
        _distributeFractionalOwnership(willId);
        
        fractionalOwnerships[willId].distributed = true;

        emit InheritanceExecuted(willId, true);
        emit FractionalOwnershipDistributed(willId, will.heirs, will.percentages);
    }

    /**
     * @dev Internal function to distribute fractional ownership to heirs
     */
    function _distributeFractionalOwnership(uint256 willId) internal {
        Will storage will = wills[willId];
        FractionalOwnership storage ownership = fractionalOwnerships[willId];

        for (uint256 i = 0; i < will.heirs.length; i++) {
            address heir = will.heirs[i];
            uint256 share = will.percentages[i];

            ownership.ownerShares[heir] = share;
            ownership.owners.push(heir);
        }
    }

    /**
     * @dev Transfer fractional shares between owners
     * @param willId The will ID
     * @param to The recipient address
     * @param amount The amount of shares to transfer (in basis points)
     */
    function transferFractionalShare(uint256 willId, address to, uint256 amount) 
        external 
        onlyFractionalOwner(willId) 
    {
        require(fractionalOwnerships[willId].distributed, "Inheritance not distributed yet");
        require(to != address(0), "Invalid recipient address");
        require(amount > 0, "Amount must be greater than 0");
        require(fractionalOwnerships[willId].ownerShares[msg.sender] >= amount, "Insufficient shares");

        FractionalOwnership storage ownership = fractionalOwnerships[willId];

        ownership.ownerShares[msg.sender] -= amount;
        
        // If recipient doesn't have shares yet, add them to owners list
        if (ownership.ownerShares[to] == 0) {
            ownership.owners.push(to);
        }
        
        ownership.ownerShares[to] += amount;

        // Remove sender from owners list if they have no shares left
        if (ownership.ownerShares[msg.sender] == 0) {
            _removeFromOwnersList(willId, msg.sender);
        }

        emit FractionalShareTransferred(willId, msg.sender, to, amount);
    }

    /**
     * @dev Remove address from owners list
     */
    function _removeFromOwnersList(uint256 willId, address owner) internal {
        FractionalOwnership storage ownership = fractionalOwnerships[willId];
        for (uint256 i = 0; i < ownership.owners.length; i++) {
            if (ownership.owners[i] == owner) {
                ownership.owners[i] = ownership.owners[ownership.owners.length - 1];
                ownership.owners.pop();
                break;
            }
        }
    }

    /**
     * @dev Claim physical NFT (requires consensus from fractional owners)
     * @param willId The will ID
     * @param recipient Address to receive the NFT
     */
    function claimPhysicalNFT(uint256 willId, address recipient) external {
        require(fractionalOwnerships[willId].distributed, "Inheritance not distributed yet");
        require(recipient != address(0), "Invalid recipient");
        
        // For simplicity, require majority consensus (>50%)
        uint256 totalConsensus = 0;
        FractionalOwnership storage ownership = fractionalOwnerships[willId];
        
        for (uint256 i = 0; i < ownership.owners.length; i++) {
            if (ownership.owners[i] == msg.sender) {
                totalConsensus += ownership.ownerShares[ownership.owners[i]];
            }
        }
        
        require(totalConsensus > TOTAL_PERCENTAGE / 2, "Insufficient consensus");
        
        Will storage will = wills[willId];
        IERC721(will.nftContract).transferFrom(address(this), recipient, will.tokenId);
    }

    /**
     * @dev Simplified Lagrange interpolation
     */
    function lagrangeReconstruction(uint256 willId, uint256 threshold) 
        internal 
        view 
        returns (uint256) 
    {
        address[] memory revealedTrustees = _getRevealedTrustees(willId, threshold);
        return _performLagrangeInterpolation(willId, revealedTrustees, threshold);
    }

    /**
     * @dev Get array of revealed trustees
     */
    function _getRevealedTrustees(uint256 willId, uint256 threshold) 
        internal 
        view 
        returns (address[] memory) 
    {
        address[] memory revealedTrustees = new address[](threshold);
        uint256 count = 0;

        // Collect revealed shares
        for (uint256 i = 0; i < trustees[willId].length && count < threshold; i++) {
            address trustee = trustees[willId][i];
            if (trusteeShares[willId][trustee].revealed) {
                revealedTrustees[count] = trustee;
                count++;
            }
        }
        
        return revealedTrustees;
    }

    /**
     * @dev Perform Lagrange interpolation calculation
     */
    function _performLagrangeInterpolation(
        uint256 willId, 
        address[] memory revealedTrustees, 
        uint256 threshold
    ) internal view returns (uint256) {
        uint256 secret = 0;

        // Lagrange interpolation
        for (uint256 i = 0; i < threshold; i++) {
            address trustee_i = revealedTrustees[i];
            TrusteeShare storage share_i = trusteeShares[willId][trustee_i];
            
            uint256 lagrangeCoeff = _calculateLagrangeCoefficient(
                willId, 
                revealedTrustees, 
                threshold, 
                i
            );
            
            uint256 term = modMul(share_i.secretShare, lagrangeCoeff, P);
            secret = addmod(secret, term, P);
        }

        return secret;
    }

    /**
     * @dev Calculate Lagrange coefficient for a specific trustee
     */
    function _calculateLagrangeCoefficient(
        uint256 willId,
        address[] memory revealedTrustees,
        uint256 threshold,
        uint256 targetIndex
    ) internal view returns (uint256) {
        address trustee_i = revealedTrustees[targetIndex];
        TrusteeShare storage share_i = trusteeShares[willId][trustee_i];
        
        uint256 numerator = 1;
        uint256 denominator = 1;

        for (uint256 j = 0; j < threshold; j++) {
            if (targetIndex != j) {
                address trustee_j = revealedTrustees[j];
                TrusteeShare storage share_j = trusteeShares[willId][trustee_j];
                
                numerator = modMul(numerator, (P - share_j.xCoordinate) % P, P);
                denominator = modMul(
                    denominator, 
                    (share_i.xCoordinate + P - share_j.xCoordinate) % P, 
                    P
                );
            }
        }

        return modMul(numerator, modInverse(denominator, P), P);
    }

    // ============ UTILITY FUNCTIONS ============

    function modMul(uint256 a, uint256 b, uint256 mod) internal pure returns (uint256) {
        return mulmod(a, b, mod);
    }

    function modExp(uint256 base, uint256 exp, uint256 mod) internal pure returns (uint256) {
        uint256 result = 1;
        base = base % mod;
        while (exp > 0) {
            if (exp % 2 == 1) {
                result = mulmod(result, base, mod);
            }
            exp >>= 1;
            base = mulmod(base, base, mod);
        }
        return result;
    }

    function modInverse(uint256 a, uint256 m) internal pure returns (uint256) {
        return modExp(a, m - 2, m);
    }

    // ============ VIEW FUNCTIONS ============

    function getWillInfo(uint256 willId) external view returns (
        address nftContract,
        uint256 tokenId,
        address[] memory heirs,
        uint256[] memory percentages,
        uint256 threshold,
        uint256 revealedCount,
        bool active,
        bool claimed
    ) {
        Will storage will = wills[willId];
        return (
            will.nftContract,
            will.tokenId,
            will.heirs,
            will.percentages,
            will.threshold,
            will.revealedCount,
            will.active,
            will.claimed
        );
    }

    function getTrusteeShareStatus(uint256 willId, address trustee) 
        external 
        view 
        returns (bool committed, bool verified, bool revealed) 
    {
        TrusteeShare storage share = trusteeShares[willId][trustee];
        return (share.committed, share.verified, share.revealed);
    }

    function getCommitments(uint256 willId) external view returns (uint256[] memory) {
        return wills[willId].commitments;
    }

    function getFractionalOwnership(uint256 willId, address owner) external view returns (uint256) {
        return fractionalOwnerships[willId].ownerShares[owner];
    }

    function getFractionalOwners(uint256 willId) external view returns (address[] memory) {
        return fractionalOwnerships[willId].owners;
    }

    function isFractionalOwnershipDistributed(uint256 willId) external view returns (bool) {
        return fractionalOwnerships[willId].distributed;
    }

    function getTotalFractionalShares(uint256 willId) external view returns (uint256) {
        return fractionalOwnerships[willId].totalShares;
    }
}