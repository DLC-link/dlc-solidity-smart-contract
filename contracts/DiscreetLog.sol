// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/KeeperCompatible.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";


contract DiscreetLog is KeeperCompatibleInterface, AccessControl {

    bytes32 public constant DLC_ADMIN_ROLE = keccak256("DLC_ADMIN_ROLE");

    string[] public openUUIDs;
    mapping(string => DLC) public dlcs;

    struct DLC {
        string UUID;
        address feedAddress;
        uint closingTime;
        int closingPrice;
        uint actualClosingTime;
    }

    struct PerformDataPack {
        string UUID;
        uint index;
    }

    event NewDLC(string UUID, address feedAddress, uint closingTime);
    event CloseDLC(string UUID, int price, uint actualClosingTime);

    constructor(address _adminAddress) {
        // set the admin of the contract
        _setupRole(DLC_ADMIN_ROLE, _adminAddress);
        // Grant the contract deployer the default admin role: it will be able
        // to grant and revoke any roles in the future if required
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function addNewDLC(string memory _UUID, address _feedAddress, uint _closingTime) external onlyRole(DLC_ADMIN_ROLE){
        require(dlcs[_UUID].feedAddress == address(0), "DLC already added");
        dlcs[_UUID] = DLC({
            UUID: _UUID,
            feedAddress: _feedAddress,
            closingTime: _closingTime,
            closingPrice: 0,
            actualClosingTime: 0
        });
        openUUIDs.push(_UUID);
        emit NewDLC(_UUID, _feedAddress, _closingTime);
    }

    // called by ChainLink Keepers (off-chain simulation, so no gas cost)
    function checkUpkeep(bytes calldata /* checkData */) external view override returns (bool upkeepNeeded, bytes memory performData) {
        for (uint256 i = 0; i < openUUIDs.length; i++) {
            DLC memory dlc = dlcs[openUUIDs[i]];
            if(dlc.closingTime <= block.timestamp && dlc.actualClosingTime == 0){  // only perform upkeep if closingTime passed and DLC not closed yet
                upkeepNeeded = true;
                performData = abi.encode(PerformDataPack({
                    UUID: openUUIDs[i],
                    index: findIndex(openUUIDs[i]) // finding the index in off-chain simulation to save gas
                }));
                break;
            }
        }
    }

    // called by ChainLink Keepers if upkeepNeeded evaluates to true in checkUpKeep
    function performUpkeep(bytes calldata performData) external override {
        PerformDataPack memory pdp = abi.decode(performData, (PerformDataPack));
        DLC storage dlc = dlcs[pdp.UUID];

        //validate again as recommended in the docs, also since upKeeps can run in parallel it can happen
        //that a DLC which is being closed gets picked up by the checkUpKeep so we can revert here
        require(dlc.closingTime <= block.timestamp && dlc.actualClosingTime == 0, 
                string(abi.encodePacked("Validation failed for performUpKeep for UUID: ", string(abi.encodePacked(pdp.UUID)))));

        (int price, uint timeStamp) = getLatestPrice(dlc.feedAddress);
        dlc.closingPrice = price;
        // TODO: discuss if the block.timestamp should be used here
        dlc.actualClosingTime = timeStamp;
        removeClosedDLC(pdp.index);
        emit CloseDLC(pdp.UUID, price, timeStamp);
    }

    function closingPriceAndTimeOfDLC(string memory _UUID) external view returns (int, uint){
        DLC memory dlc = dlcs[_UUID];
        require(dlc.actualClosingTime > 0, "The requested DLC is not closed yet");
        return (dlc.closingPrice, dlc.actualClosingTime);
    }

    function allOpenDLC() external view returns (string[] memory) {
        return openUUIDs;
    }

    function getLatestPrice(address _feedAddress) internal view returns (int, uint) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(_feedAddress);
        (,int price,,uint timeStamp,) = priceFeed.latestRoundData();
        return (price, timeStamp);
    }

    // note: this remove not preserving the order
    function removeClosedDLC(uint index) private returns(string[] memory) {
        require(index < openUUIDs.length);
        // Move the last element to the deleted spot
        openUUIDs[index] = openUUIDs[openUUIDs.length-1];
        // Remove the last element
        openUUIDs.pop();
        return openUUIDs;
    }

    function findIndex(string memory _UUID) private view returns (uint) {
        // find the recently closed UUID index
        for (uint i = 0; i < openUUIDs.length; i++){
            if(keccak256(abi.encodePacked(openUUIDs[i])) == keccak256(abi.encodePacked(_UUID))){
                return i;
            }
        }
        revert("Not Found"); // should not happen just in case
    }
}

