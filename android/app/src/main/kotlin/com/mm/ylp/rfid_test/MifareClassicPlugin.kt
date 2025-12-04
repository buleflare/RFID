package com.mm.ylp.rfid_test

import android.app.Activity
import android.content.Intent
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.MifareClassic
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object MifareClassicPlugin {

    private var eventSink: EventChannel.EventSink? = null
    private var currentTag: Tag? = null

    fun setup(flutterEngine: FlutterEngine, activity: Activity) {
        val methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mifare_classic/method")
        val eventChannel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "mifare_classic/events")

        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "startScan" -> result.success(true)
                "writeData" -> writeData(call, result)
                else -> result.notImplemented()
            }
        }

        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    fun onNewIntent(activity: Activity, intent: Intent) {
        val action = intent.action
        if (action == NfcAdapter.ACTION_TAG_DISCOVERED || action == NfcAdapter.ACTION_TECH_DISCOVERED) {
            val tag: Tag? = intent.getParcelableExtra(NfcAdapter.EXTRA_TAG)
            tag?.let {
                currentTag = it
                readAllBlocks(it)
            }
        }
    }

    private fun readAllBlocks(tag: Tag) {
        try {
            println("DEBUG: Starting readAllBlocks")
            val mifare = MifareClassic.get(tag) ?: return

            // Get the FULL UID from the tag
            val fullUidBytes = tag.id
            val fullUidHex = bytesToHex(fullUidBytes)
            println("DEBUG: Full UID bytes: ${fullUidBytes.size} - Hex: $fullUidHex")

            // For Mifare Classic, UID should be 4 or 7 bytes
            val uidToSend = if (fullUidBytes.size >= 7) {
                // Take first 7 bytes for extended UID
                bytesToHex(fullUidBytes.copyOfRange(0, 7))
            } else {
                // Use whatever we have
                fullUidHex
            }

            println("DEBUG: UID to send: $uidToSend")

            val type = mifare.type
            val size = mifare.size
            val sectorCount = mifare.sectorCount
            println("DEBUG: Card type: $type, size: $size, sectors: $sectorCount")

            mifare.connect()
            println("DEBUG: Connected to tag")

            val resultList = mutableListOf<Map<String, Any>>()
            var successfulSectors = 0

            // Define possible keys to try
            val commonKeys = arrayOf(
                byteArrayOf(0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte()),
                byteArrayOf(0xA0.toByte(), 0xA1.toByte(), 0xA2.toByte(), 0xA3.toByte(), 0xA4.toByte(), 0xA5.toByte()),
                byteArrayOf(0xD3.toByte(), 0xF7.toByte(), 0xD3.toByte(), 0xF7.toByte(), 0xD3.toByte(), 0xF7.toByte()),
                byteArrayOf(0x00.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte())
            )

            for (sector in 0 until sectorCount) {
                println("DEBUG: Trying sector $sector")
                var authenticated = false
                var usedKey: ByteArray? = null

                // Try key A first
                for (key in commonKeys) {
                    try {
                        authenticated = mifare.authenticateSectorWithKeyA(sector, key)
                        if (authenticated) {
                            usedKey = key
                            println("DEBUG: Sector $sector authenticated with key A: ${bytesToHex(key)}")
                            break
                        }
                    } catch (e: Exception) {
                        // Continue to next key
                    }
                }

                // Try key B if key A fails
                if (!authenticated) {
                    for (key in commonKeys) {
                        try {
                            authenticated = mifare.authenticateSectorWithKeyB(sector, key)
                            if (authenticated) {
                                usedKey = key
                                println("DEBUG: Sector $sector authenticated with key B: ${bytesToHex(key)}")
                                break
                            }
                        } catch (e: Exception) {
                            // Continue to next key
                        }
                    }
                }

                if (authenticated) {
                    successfulSectors++
                    val startBlock = mifare.sectorToBlock(sector)
                    val blockCount = mifare.getBlockCountInSector(sector)
                    println("DEBUG: Sector $sector - startBlock: $startBlock, blockCount: $blockCount")

                    for (block in 0 until blockCount) {
                        val absBlock = startBlock + block

                        // Check if this is a trailer block (last block in sector)
                        val isTrailer = (block == blockCount - 1)

                        try {
                            val data = mifare.readBlock(absBlock)
                            val hexStr = bytesToHex(data)
                            val textStr = data.map { if (it in 32..126) it.toChar() else '.' }.joinToString("")

                            resultList.add(
                                mapOf(
                                    "sector" to sector,
                                    "block" to block,
                                    "absBlock" to absBlock,
                                    "hex" to hexStr,
                                    "text" to textStr,
                                    "isTrailer" to isTrailer
                                )
                            )

                            println("DEBUG: Read block $absBlock (sector $sector, block $block): $hexStr")
                        } catch (e: Exception) {
                            println("DEBUG: Failed to read block $absBlock: ${e.message}")
                            resultList.add(
                                mapOf(
                                    "sector" to sector,
                                    "block" to block,
                                    "absBlock" to absBlock,
                                    "hex" to "READ ERROR",
                                    "text" to "READ ERROR",
                                    "isTrailer" to isTrailer
                                )
                            )
                        }
                    }
                } else {
                    println("DEBUG: Failed to authenticate sector $sector")
                    val startBlock = mifare.sectorToBlock(sector)
                    val blockCount = mifare.getBlockCountInSector(sector)

                    for (block in 0 until blockCount) {
                        val absBlock = startBlock + block
                        val isTrailer = (block == blockCount - 1)

                        resultList.add(
                            mapOf(
                                "sector" to sector,
                                "block" to block,
                                "absBlock" to absBlock,
                                "hex" to "AUTH ERROR",
                                "text" to "AUTH ERROR",
                                "isTrailer" to isTrailer
                            )
                        )
                    }
                }
            }

            mifare.close()
            println("DEBUG: Successfully read $successfulSectors sectors, ${resultList.size} blocks total")

            eventSink?.success(
                mapOf(
                    "uid" to uidToSend,
                    "blocks" to resultList,
                    "type" to type.toString(),
                    "size" to size,
                    "sectorCount" to sectorCount,
                    "successfulSectors" to successfulSectors,
                    "fullUid" to uidToSend
                )
            )

        } catch (e: Exception) {
            println("DEBUG: Error in readAllBlocks: ${e.message}")
            e.printStackTrace()
            eventSink?.success(mapOf("error" to "Read error: ${e.message}"))
        }
    }



    private fun _clearAllBlocks(mifare: MifareClassic, result: MethodChannel.Result) {
        try {
            println("DEBUG: Starting to clear all writable blocks with zeros")

            val sectorCount = mifare.sectorCount
            val zeroBlock = ByteArray(16) { 0x00 }
            var clearedBlocks = 0
            var failedBlocks = 0
            val clearedSectors = mutableListOf<Int>()

            // Define common keys - prioritize D3F7 key for NFC Forum tags
            val commonKeys = arrayOf(
                byteArrayOf(0xD3.toByte(), 0xF7.toByte(), 0xD3.toByte(), 0xF7.toByte(), 0xD3.toByte(), 0xF7.toByte()),
                byteArrayOf(0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte()),
                byteArrayOf(0xA0.toByte(), 0xA1.toByte(), 0xA2.toByte(), 0xA3.toByte(), 0xA4.toByte(), 0xA5.toByte()),
                byteArrayOf(0x00.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte())
            )

            for (sector in 0 until sectorCount) {
                println("DEBUG: Attempting to clear sector $sector")

                // Skip sector 0 (manufacturer block) - usually read-only
                if (sector == 0) {
                    println("DEBUG: Skipping sector 0 (manufacturer block)")
                    continue
                }

                var authenticated = false
                var authKey: ByteArray? = null

                // Try to authenticate with all keys
                for (key in commonKeys) {
                    try {
                        // Try key A first
                        authenticated = mifare.authenticateSectorWithKeyA(sector, key)
                        if (authenticated) {
                            authKey = key
                            println("DEBUG: Sector $sector authenticated with Key A: ${bytesToHex(key)}")
                            break
                        }
                    } catch (e: Exception) {
                        println("DEBUG: Key A failed for sector $sector: ${e.message}")
                    }

                    if (!authenticated) {
                        try {
                            // Try key B
                            authenticated = mifare.authenticateSectorWithKeyB(sector, key)
                            if (authenticated) {
                                authKey = key
                                println("DEBUG: Sector $sector authenticated with Key B: ${bytesToHex(key)}")
                                break
                            }
                        } catch (e: Exception) {
                            println("DEBUG: Key B failed for sector $sector: ${e.message}")
                        }
                    }
                }

                if (authenticated) {
                    try {
                        val startBlock = mifare.sectorToBlock(sector)
                        val blockCount = mifare.getBlockCountInSector(sector)
                        println("DEBUG: Sector $sector has $blockCount blocks, starting at $startBlock")

                        // Clear data blocks only (skip trailer blocks)
                        // Sector structure:
                        // - Sector 0-31: 4 blocks per sector (3 data + 1 trailer)
                        // - Sector 32-39: 16 blocks per sector (15 data + 1 trailer)

                        val dataBlocks = blockCount - 1 // Exclude trailer block

                        for (relativeBlock in 0 until dataBlocks) {
                            val absBlock = startBlock + relativeBlock

                            try {
                                // Check if this is a manufacturer block (block 0)
                                if (absBlock == 0) {
                                    println("DEBUG: Skipping manufacturer block 0")
                                    continue
                                }

                                println("DEBUG: Attempting to clear block $absBlock")

                                // Try to write zeros
                                mifare.writeBlock(absBlock, zeroBlock)

                                // Verify the write
                                val verifyData = mifare.readBlock(absBlock)
                                if (verifyData.contentEquals(zeroBlock)) {
                                    clearedBlocks++
                                    println("DEBUG: Successfully cleared block $absBlock")
                                } else {
                                    failedBlocks++
                                    println("DEBUG: Verification failed for block $absBlock")
                                }

                            } catch (e: Exception) {
                                failedBlocks++
                                println("DEBUG: Failed to clear block $absBlock: ${e.message}")
                                // Continue with next block
                            }
                        }

                        clearedSectors.add(sector)
                        println("DEBUG: Completed clearing sector $sector")

                    } catch (e: Exception) {
                        println("DEBUG: Error processing sector $sector: ${e.message}")
                        failedBlocks += 3 // Approximate count for this sector
                    }
                } else {
                    println("DEBUG: Could not authenticate sector $sector - skipping")
                    failedBlocks += 3 // Approximate count for this sector
                }
            }

            mifare.close()

            println("DEBUG: Clear operation completed:")
            println("DEBUG:   Cleared blocks: $clearedBlocks")
            println("DEBUG:   Failed blocks: $failedBlocks")
            println("DEBUG:   Cleared sectors: $clearedSectors")

            if (clearedBlocks > 0) {
                // Read the card again to show cleared state
                try {
                    currentTag?.let {
                        println("DEBUG: Re-reading card after clear operation")
                        readAllBlocks(it)
                    }
                } catch (e: Exception) {
                    println("DEBUG: Error re-reading card: ${e.message}")
                    // Still return success if we cleared at least one block
                }

                result.success(true)
            } else {
                val errorMsg = if (failedBlocks > 0) {
                    "Could not clear any blocks. Card may be locked or use different keys."
                } else {
                    "No blocks were cleared. Card may be read-only or already cleared."
                }
                throw Exception(errorMsg)
            }

        } catch (e: Exception) {
            println("DEBUG: Exception in _clearAllBlocks: ${e.message}")
            e.printStackTrace()

            // Try to close the connection
            try {
                mifare.close()
            } catch (closeE: Exception) {
                println("DEBUG: Error closing connection: ${closeE.message}")
            }

            throw Exception("Clear operation failed: ${e.message}")
        }
    }

    private fun writeData(call: MethodCall, result: MethodChannel.Result) {
        try {
            val dataString = call.argument<String>("data") ?: ""
            val isHex = call.argument<Boolean>("isHex") ?: false
            // Remove clearCard parameter

            val tag = currentTag ?: run {
                result.error("NO_TAG", "No tag detected. Please bring card closer.", null)
                return
            }

            println("DEBUG: Starting writeData operation")
            println("DEBUG:   isHex: $isHex")
            println("DEBUG:   data length: ${dataString.length}")
            println("DEBUG:   first 20 chars: ${dataString.take(20)}")

            val mifare = MifareClassic.get(tag) ?: throw Exception("Not a Mifare Classic tag")

            try {
                mifare.connect()
                println("DEBUG: Connected to Mifare Classic tag")

                // Always use normal write (no more clear card)
                _writeNormalData(mifare, dataString, isHex, result)
            } catch (connectError: Exception) {
                throw Exception("Failed to connect to tag: ${connectError.message}")
            }

        } catch (e: Exception) {
            println("DEBUG: Write error: ${e.message}")
            e.printStackTrace()
            result.error("WRITE_ERROR", e.message, null)
        }
    }

    private fun _writeNormalData(mifare: MifareClassic, dataString: String, isHex: Boolean, result: MethodChannel.Result) {
        // Convert data to bytes
        val bytes = if (isHex) {
            // Validate hex string
            val cleanHex = dataString.replace("\\s".toRegex(), "").uppercase()

            // Check if string contains only hex characters
            if (!cleanHex.matches(Regex("[0-9A-F]+"))) {
                throw Exception("Invalid hex characters. Use only 0-9, A-F.")
            }

            if (cleanHex.length % 2 != 0) {
                throw Exception("Invalid hex string length. Must be even number of characters.")
            }

            try {
                ByteArray(cleanHex.length / 2) { i ->
                    cleanHex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
                }
            } catch (e: Exception) {
                throw Exception("Invalid hex format: ${e.message}")
            }
        } else {
            dataString.toByteArray(Charsets.UTF_8)
        }

        // Check if bytes array is empty
        if (bytes.isEmpty()) {
            throw Exception("No data to write")
        }

        println("DEBUG: Data to write (${bytes.size} bytes): ${bytesToHex(bytes.take(32).toByteArray())}...")

        val sectorCount = mifare.sectorCount
        println("DEBUG: Total sectors: $sectorCount")

        // Track writing progress
        var totalBytesWritten = 0
        var totalBlocksWritten = 0
        val maxWritableBytes = 768 // Mifare Classic 1K capacity (48 blocks * 16 bytes)

        // If data is longer than capacity, truncate it
        val dataToWrite = if (bytes.size > maxWritableBytes) {
            println("DEBUG: Data too long (${bytes.size} > $maxWritableBytes bytes), truncating")
            bytes.copyOf(maxWritableBytes)
        } else {
            bytes
        }

        println("DEBUG: Will write ${dataToWrite.size} bytes to card")
        println("DEBUG: Need ${(dataToWrite.size + 15) / 16} blocks")

        // Write data across ALL writable sectors and blocks
        var dataIndex = 0

        // Define common keys to try for authentication
        val commonKeys = arrayOf(
            byteArrayOf(0xD3.toByte(), 0xF7.toByte(), 0xD3.toByte(), 0xF7.toByte(), 0xD3.toByte(), 0xF7.toByte()),
            byteArrayOf(0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte()),
            byteArrayOf(0xA0.toByte(), 0xA1.toByte(), 0xA2.toByte(), 0xA3.toByte(), 0xA4.toByte(), 0xA5.toByte()),
            byteArrayOf(0x00.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte(), 0x00.toByte())
        )

        // Start from sector 1 (skip sector 0 which is manufacturer)
        for (sector in 1 until sectorCount) {
            // Check if we have more data to write
            if (dataIndex >= dataToWrite.size) {
                println("DEBUG: All data written (stopping at sector $sector)")
                break
            }

            println("DEBUG: === Processing sector $sector ===")

            // Try to authenticate sector
            var authenticated = false
            var authKey: ByteArray? = null

            for (key in commonKeys) {
                try {
                    authenticated = mifare.authenticateSectorWithKeyA(sector, key)
                    if (authenticated) {
                        authKey = key
                        println("DEBUG: Sector $sector authenticated with Key A: ${bytesToHex(key)}")
                        break
                    }
                } catch (e: Exception) {
                    println("DEBUG: Key A failed for sector $sector: ${e.message}")
                }

                if (!authenticated) {
                    try {
                        authenticated = mifare.authenticateSectorWithKeyB(sector, key)
                        if (authenticated) {
                            authKey = key
                            println("DEBUG: Sector $sector authenticated with Key B: ${bytesToHex(key)}")
                            break
                        }
                    } catch (e: Exception) {
                        println("DEBUG: Key B failed for sector $sector: ${e.message}")
                    }
                }
            }

            if (!authenticated) {
                println("DEBUG: Could not authenticate sector $sector, moving to next sector")
                continue
            }

            // Get sector information
            val startBlock = mifare.sectorToBlock(sector)
            val blockCount = mifare.getBlockCountInSector(sector)
            val dataBlocks = blockCount - 1 // Exclude trailer block

            println("DEBUG: Sector $sector - startBlock: $startBlock, total blocks: $blockCount, data blocks: $dataBlocks")

            // Write to all data blocks in this sector
            for (blockOffset in 0 until dataBlocks) {
                // Check if we have more data to write
                if (dataIndex >= dataToWrite.size) {
                    println("DEBUG: All data written (stopping at block $blockOffset)")
                    break
                }

                val absBlock = startBlock + blockOffset
                val blockData = ByteArray(16) { 0x00 }
                val bytesToCopy = minOf(16, dataToWrite.size - dataIndex)

                // Copy data to block
                System.arraycopy(dataToWrite, dataIndex, blockData, 0, bytesToCopy)

                try {
                    println("DEBUG: Writing to block $absBlock (sector $sector, block $blockOffset)")
                    println("DEBUG:   Data: ${bytesToHex(blockData)}")
                    mifare.writeBlock(absBlock, blockData)

                    // Verify write
                    val verifyData = mifare.readBlock(absBlock)
                    if (!verifyData.contentEquals(blockData)) {
                        println("DEBUG:   Verification FAILED for block $absBlock")
                        println("DEBUG:   Expected: ${bytesToHex(blockData)}")
                        println("DEBUG:   Got: ${bytesToHex(verifyData)}")
                        // Continue anyway, but note the failure
                    } else {
                        println("DEBUG:   Verification OK")
                    }

                    dataIndex += bytesToCopy
                    totalBytesWritten += bytesToCopy
                    totalBlocksWritten++

                    println("DEBUG:   Successfully wrote $bytesToCopy bytes")
                    println("DEBUG:   Total so far: $totalBytesWritten bytes in $totalBlocksWritten blocks")

                } catch (e: Exception) {
                    println("DEBUG: Failed to write block $absBlock: ${e.message}")
                    // Continue with next block instead of failing completely
                }
            }

            println("DEBUG: === Finished sector $sector ===")
            println("DEBUG: Bytes written so far: $totalBytesWritten/${dataToWrite.size}")
        }

        mifare.close()

        println("DEBUG: ===== WRITE COMPLETED =====")
        println("DEBUG: Total bytes written: $totalBytesWritten/${dataToWrite.size}")
        println("DEBUG: Total blocks written: $totalBlocksWritten")
        println("DEBUG: Remaining data not written: ${dataToWrite.size - totalBytesWritten} bytes")

        if (totalBytesWritten == 0) {
            throw Exception("Could not write any data. Card may be locked or authentication failed.")
        }
        if (totalBytesWritten < dataToWrite.size) {
            println("DEBUG: Warning: Only wrote $totalBytesWritten of ${dataToWrite.size} bytes")
        }
        // Read the card again to show updated data
        currentTag?.let {
            println("DEBUG: Re-reading card to verify write...")
            readAllBlocks(it)
        }
        result.success(true)
    }

    private fun bytesToHex(bytes: ByteArray): String {
        if (bytes.isEmpty()) return ""

        val hexChars = CharArray(bytes.size * 2)
        for (i in bytes.indices) {
            val v = bytes[i].toInt() and 0xFF
            hexChars[i * 2] = "0123456789ABCDEF"[v ushr 4]
            hexChars[i * 2 + 1] = "0123456789ABCDEF"[v and 0x0F]
        }
        return String(hexChars)
    }
}