.PHONY: all test clean deploy

# Load environment variables from .env file
include .env
export

# Default target
all: clean install build test

# Install dependencies
install:
	forge install foundry-rs/forge-std

# Build the project
build:
	forge build

# Run tests (using test profile to suppress size warnings)
test:
	FOUNDRY_PROFILE=test forge test -vv

# Run tests with gas reporting
test-gas:
	FOUNDRY_PROFILE=test forge test --gas-report

# Run tests with coverage
coverage:
	forge coverage

# Clean build artifacts
clean:
	forge clean

# Format code
format:
	forge fmt

# Deploy to Sepolia
deploy-sepolia:
	@echo "Deploying to Sepolia..."
	forge script script/DeployDeFiModule.s.sol \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--broadcast \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		-vvvv

# Deploy paymaster
deploy-paymaster:
	@echo "Deploying to Sepolia..."
	forge script script/DeployPaymaster.s.sol \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--broadcast \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		-vvvv

# Setup roles and permissions
setup-roles:
	@echo "Setting up roles..."
	forge script script/SetupDeFiModule.s.sol \
		--rpc-url $(SEPOLIA_RPC_URL) \
		--broadcast \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		-vvvv

# ============ Base Sepolia Deployment ============

# Deploy Registry on Base Sepolia
deploy-base-sepolia-registry:
	@echo "Deploying Registry to Base Sepolia..."
	forge script script/DeployRegistry.s.sol \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--verify --verifier-url https://api-sepolia.basescan.org/api \
		-vvvv

# Deploy Factory on Base Sepolia (requires REGISTRY_ADDRESS)
deploy-base-sepolia-factory:
	@echo "Deploying Factory to Base Sepolia..."
	forge script script/DeployFactory.s.sol \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--verify --verifier-url https://api-sepolia.basescan.org/api \
		-vvvv

# Deploy module via Factory on Base Sepolia (requires FACTORY_ADDRESS, SAFE_ADDRESS, AUTHORIZED_UPDATER)
deploy-base-sepolia-module:
	@echo "Deploying Module via Factory on Base Sepolia..."
	forge script script/DeployModuleViaFactory.s.sol \
		--rpc-url $(BASE_SEPOLIA_RPC_URL) \
		--broadcast \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--verify --verifier-url https://api-sepolia.basescan.org/api \
		-vvvv

# Full Base Sepolia stack: Registry → Factory
deploy-base-sepolia: deploy-base-sepolia-registry deploy-base-sepolia-factory
	@echo "Base Sepolia deployment complete."
	@echo "Next: deploy a module with make deploy-base-sepolia-module"

# ============ Base Mainnet Deployment ============

deploy-base-registry:
	@echo "Deploying Registry to Base..."
	forge script script/DeployRegistry.s.sol \
		--rpc-url $(BASE_RPC_URL) \
		--broadcast \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--verify \
		-vvvv

deploy-base-factory:
	@echo "Deploying Factory to Base..."
	forge script script/DeployFactory.s.sol \
		--rpc-url $(BASE_RPC_URL) \
		--broadcast \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		--verify \
		-vvvv

deploy-base: deploy-base-registry deploy-base-factory
	@echo "Base mainnet deployment complete."

# ============ Configuration ============

# Configure parsers and selectors on any chain
configure-module:
	@echo "Configuring parsers and selectors..."
	forge script script/ConfigureParsersAndSelectors.s.sol \
		--rpc-url $(RPC_URL) \
		--broadcast \
		--private-key $(DEPLOYER_PRIVATE_KEY) \
		-vvvv

# ============ Verification ============

# Verify contracts on Etherscan (Sepolia)
verify:
	@echo "Verifying contracts..."
	forge verify-contract \
		$(DEFI_MODULE_ADDRESS) \
		src/DeFiInteractorModule.sol:DeFiInteractorModule \
		--chain-id 11155111 \
		--constructor-args $(shell cast abi-encode "constructor(address,address)" $(SAFE_ADDRESS) $(SAFE_ADDRESS))

# Verify contracts on Basescan
verify-base:
	@echo "Verifying on Basescan..."
	forge verify-contract \
		$(DEFI_MODULE_ADDRESS) \
		src/DeFiInteractorModule.sol:DeFiInteractorModule \
		--chain-id 8453 \
		--verifier-url https://api.basescan.org/api \
		--etherscan-api-key $(BASESCAN_API_KEY) \
		--constructor-args $(shell cast abi-encode "constructor(address,address,address)" $(SAFE_ADDRESS) $(SAFE_ADDRESS) $(AUTHORIZED_UPDATER))

# Run local node for testing
anvil:
	anvil

# Help
help:
	@echo "Available commands:"
	@echo "  make install                      - Install dependencies"
	@echo "  make build                        - Build contracts"
	@echo "  make test                         - Run tests"
	@echo "  make test-gas                     - Run tests with gas reporting"
	@echo "  make coverage                     - Generate coverage report"
	@echo "  make clean                        - Clean build artifacts"
	@echo "  make format                       - Format code"
	@echo ""
	@echo "  Sepolia:"
	@echo "  make deploy-sepolia               - Deploy DeFiInteractorModule to Sepolia"
	@echo "  make verify                       - Verify contracts on Etherscan"
	@echo ""
	@echo "  Base Sepolia (staging):"
	@echo "  make deploy-base-sepolia          - Deploy full stack (Registry + Factory + VaultFactory)"
	@echo "  make deploy-base-sepolia-registry - Deploy Registry only"
	@echo "  make deploy-base-sepolia-factory  - Deploy ModuleFactory only"
	@echo "  make deploy-base-sepolia-module   - Deploy module for a Safe via Factory"
	@echo ""
	@echo "  Base Mainnet:"
	@echo "  make deploy-base                  - Deploy full stack (Registry + Factory + VaultFactory)"
	@echo "  make verify-base                  - Verify contracts on Basescan"
	@echo ""
	@echo "  make configure-module             - Configure parsers/selectors (set RPC_URL)"
	@echo "  make anvil                        - Run local test node"
