//import Foundation
//
//public struct ValidationResult {
//    public let isValid: Bool
//    public let errors: [String]
//    
//    public init(isValid: Bool, errors: [String] = []) {
//        self.isValid = isValid
//        self.errors = errors
//    }
//}
//
//public class Validator {
//    
//    public static func validateTransaction(_ transaction: Transaction, blockchain: Blockchain? = nil) -> ValidationResult {
//        var errors: [String] = []
//        
//        if transaction.id.isEmpty {
//            errors.append("Transaction ID cannot be empty")
//        }
//        
//        if transaction.inputs.isEmpty {
//            errors.append("Transaction must have at least one input")
//        }
//        
//        if transaction.outputs.isEmpty {
//            errors.append("Transaction must have at least one output")
//        }
//        
//        for output in transaction.outputs {
//            if output.amount <= 0 {
//                errors.append("Output amount must be positive")
//            }
//            
//            if !Wallet.validateAddress(output.address) {
//                errors.append("Invalid output address: \(output.address)")
//            }
//        }
//        
//        if transaction.fee < 0 {
//            errors.append("Transaction fee cannot be negative")
//        }
//        
//        if let blockchain = blockchain {
//            for input in transaction.inputs where input.transactionId != "coinbase" {
//                let senderBalance = blockchain.getBalance(address: input.publicKey)
//                if senderBalance < transaction.totalOutputAmount + transaction.fee {
//                    errors.append("Insufficient balance for sender: \(input.publicKey)")
//                }
//            }
//        }
//        
//        let calculatedId = Transaction.calculateId(
//            inputs: transaction.inputs,
//            outputs: transaction.outputs,
//            timestamp: transaction.timestamp
//        )
//        
//        if transaction.id != calculatedId {
//            errors.append("Transaction ID does not match calculated ID")
//        }
//        
//        return ValidationResult(isValid: errors.isEmpty, errors: errors)
//    }
//    
//    public static func validateBlock(_ block: Block, previousBlock: Block? = nil) -> ValidationResult {
//        var errors: [String] = []
//        
//        if block.hash.isEmpty {
//            errors.append("Block hash cannot be empty")
//        }
//        
//        if block.transactions.isEmpty {
//            errors.append("Block must contain at least one transaction")
//        }
//        
//        let calculatedHash = Block.calculateHash(header: block.header, transactions: block.transactions)
//        if block.hash != calculatedHash {
//            errors.append("Block hash does not match calculated hash")
//        }
//        
//        if let prevBlock = previousBlock {
//            if block.header.previousHash != prevBlock.hash {
//                errors.append("Block's previous hash does not match previous block's hash")
//            }
//            
//            if block.header.index != prevBlock.header.index + 1 {
//                errors.append("Block index is not sequential")
//            }
//            
//            if block.header.timestamp < prevBlock.header.timestamp {
//                errors.append("Block timestamp is before previous block")
//            }
//        } else {
//            if block.header.index != 0 {
//                errors.append("Genesis block must have index 0")
//            }
//            
//            if !block.header.previousHash.isEmpty {
//                errors.append("Genesis block must have empty previous hash")
//            }
//        }
//        
//        let calculatedMerkleRoot = Block.calculateMerkleRoot(transactions: block.transactions)
//        if block.header.merkleRoot != calculatedMerkleRoot {
//            errors.append("Merkle root does not match calculated merkle root")
//        }
//        
//        let target = String(repeating: "0", count: Int(block.header.difficulty))
//        if !block.hash.hasPrefix(target) {
//            errors.append("Block hash does not meet difficulty requirement")
//        }
//        
//        var coinbaseCount = 0
//        for transaction in block.transactions {
//            let transactionValidation = validateTransaction(transaction)
//            if !transactionValidation.isValid {
//                errors.append(contentsOf: transactionValidation.errors.map { "Transaction error: \($0)" })
//            }
//            
//            if transaction.inputs.contains(where: { $0.transactionId == "coinbase" }) {
//                coinbaseCount += 1
//            }
//        }
//        
//        if coinbaseCount != 1 {
//            errors.append("Block must contain exactly one coinbase transaction")
//        }
//        
//        return ValidationResult(isValid: errors.isEmpty, errors: errors)
//    }
//    
//    public static func validateBlockchain(_ blockchain: Blockchain) -> ValidationResult {
//        var errors: [String] = []
//        let blocks = blockchain.blocks
//        
//        if blocks.isEmpty {
//            errors.append("Blockchain cannot be empty")
//            return ValidationResult(isValid: false, errors: errors)
//        }
//        
//        let genesisValidation = validateBlock(blocks[0])
//        if !genesisValidation.isValid {
//            errors.append(contentsOf: genesisValidation.errors.map { "Genesis block error: \($0)" })
//        }
//        
//        for i in 1..<blocks.count {
//            let currentBlock = blocks[i]
//            let previousBlock = blocks[i - 1]
//            
//            let blockValidation = validateBlock(currentBlock, previousBlock: previousBlock)
//            if !blockValidation.isValid {
//                errors.append(contentsOf: blockValidation.errors.map { "Block \(i) error: \($0)" })
//            }
//        }
//        
//        return ValidationResult(isValid: errors.isEmpty, errors: errors)
//    }
//    
//    public static func validateSignature(_ transaction: Transaction, wallet: Wallet) -> ValidationResult {
//        var errors: [String] = []
//        
//        for input in transaction.inputs {
//            let transactionData = "\(transaction.id)\(transaction.timestamp.timeIntervalSince1970)"
//            
//            if !CryptoUtils.verify(message: transactionData, signature: input.signature, publicKeyHex: input.publicKey) {
//                errors.append("Invalid signature for input with public key: \(input.publicKey)")
//            }
//        }
//        
//        return ValidationResult(isValid: errors.isEmpty, errors: errors)
//    }
//    
//    public static func validateDifficulty(_ difficulty: UInt32) -> ValidationResult {
//        var errors: [String] = []
//        
//        if difficulty < 1 {
//            errors.append("Difficulty must be at least 1")
//        }
//        
//        if difficulty > 20 {
//            errors.append("Difficulty cannot exceed 20 (impractical)")
//        }
//        
//        return ValidationResult(isValid: errors.isEmpty, errors: errors)
//    }
//}
