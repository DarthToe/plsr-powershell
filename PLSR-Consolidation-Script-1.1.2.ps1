#######################################################################################################################
#
# VERSION 1.1.2 - Pulsar Coin (PLSR) UTXO Consolidation Script
# Written for Powershell.
# Change .txt file extension to .ps1 file extension.
# Purpose: (a.) automatic UTXO consolidation and (b.) automatic orphan transaction abandonment
# Download the Pulsar Coin wallet - https://github.com/Pulsar-Coin/Pulsar-Coin-Cryptocurrency
# WARNING: Always security audit any script found online through Google Gemini or ChatGPT before use.
# Inspiration: https://github.com/Pulsar-Coin/Consolidation-Script
#
#######################################################################################################################

Clear-Host

# Define RPC connection variables here for easy input
$rpcIP = "127.0.0.1"        # Replace with your RPC server IP
$rpcPort = "5996"           # Replace with your RPC port
$rpcUser = "username"       # Replace with your RPC username
$rpcPass = "password"       # Replace with your RPC password
$minConsolidation = 250000  # Replace with minimum amount for consolidation
$consolidationInterval = 60 # Time interval (in seconds) between consolidations
$PULSARDIR = "C:\path\to\pulsar-cli.exe"  # Define pulsar-cli path

# User-defined variables for consolidation and abandonment
$utxoThreshold = 10          # Default value: UTXO threshold to trigger consolidation (can be set by the user)
$enableConsolidation = $true # Enable or disable UTXO consolidation (can be set by the user)
$enableAutoAbandon = $true   # Enable or disable auto-abandon of orphaned staking transactions (can be set by the user)

$Global:abandon = 0
$Global:consolidated = 0

function Show-Info($message) {
    Write-Host $message -ForegroundColor Green
}

function Show-Warning($message) {
    Write-Host $message -ForegroundColor Yellow
}

function Show-Error($message) {
    Write-Host $message -ForegroundColor Red
}

# Function to consolidate UTXOs
function consolidate() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$rpcIP,
        [Parameter(Mandatory=$true)]$rpcPort,
        [Parameter(Mandatory=$true)]$rpcUser,
        [Parameter(Mandatory=$true)]$rpcPass,
        [Parameter(Mandatory=$true)]$minConsolidation,
        [Parameter(Mandatory=$true)]$utxoThreshold
    )

    if (-not $enableConsolidation) {
        Show-Warning "Consolidation is disabled. Skipping..."
        return
    }

    Show-Info "`nFetching UTXO data from the node..."

    try {
        $data = (& "$PULSARDIR\pulsar-cli.exe" -rpcconnect="$rpcIP" -rpcport="$rpcPort" -rpcuser="$rpcUser" -rpcpassword="$rpcPass" listunspent)
        $data = $data | ConvertFrom-Json
        if (-not $data) {
            Show-Error "No UTXO Data Found or Parsing Failed"
            return
        }

        # Filter spendable UTXOs with amounts less than the minimum consolidation amount
        $data = $data | Where { $_.spendable -eq "True" -and $_.amount -lt $minConsolidation }

        if ($data.Count -lt 1) {
            Show-Info "No Transactions to Consolidate. Total Consolidations: $Global:consolidated"
        } else {
            # Group UTXOs by address and consolidate only addresses with user-specified UTXO threshold
            $groupedData = $data | Group-Object -Property address | Where-Object { $_.Group.Count -ge $utxoThreshold }

            foreach ($group in $groupedData) {
                $address = $group.Name
                $utxoCount = $group.Group.Count
                Show-Info "`n--- Checking Address: $address ---"
                Show-Info "Total UTXOs for ${address}: ${utxoCount}"

                $batchSize = 100
                $batchCount = [math]::Ceiling($utxoCount / $batchSize)

                for ($i = 0; $i -lt $batchCount; $i++) {
                    $start = $i * $batchSize
                    $batch = $group.Group | Select-Object -Skip $start -First $batchSize
                    Show-Info "Batch $($i + 1) - Consolidating $(${batch.txid.Count}) UTXOs"

                    if ($batch.txid.Count -gt 1) {
                        $totalAmount = ($batch | Measure-Object -Property amount -Sum).Sum
                        Show-Info "Total Amount for Batch: ${totalAmount} PLS"

                        $Global:consolidated++
                        send -rpcIP "$rpcIP" -rpcPort "$rpcPort" -rpcUser "$rpcUser" -rpcPass "$rpcPass" -utxos $batch
                        Start-Sleep -Seconds 1
                    }
                }
            }
            Show-Info "`nTotal Consolidations Done: $Global:consolidated"
        }
    } catch {
        Show-Error "Error consolidating UTXOs: $_"
    }
}

# Function to abandon orphaned staking transactions with additional transaction structure logging
function abandon() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$rpcIP,
        [Parameter(Mandatory=$true)]$rpcPort,
        [Parameter(Mandatory=$true)]$rpcUser,
        [Parameter(Mandatory=$true)]$rpcPass
    )

    if (-not $enableAutoAbandon) {
        Show-Warning "Auto-abandon is disabled. Skipping..."
        return
    }

    Show-Info "`nChecking for orphaned stake-orphan transactions..."

    try {
        # Fetch the list of transactions from the node
        $txs = (& "$PULSARDIR\pulsar-cli.exe" -rpcconnect="$rpcIP" -rpcport="$rpcPort" -rpcuser="$rpcUser" -rpcpassword="$rpcPass" listtransactions "*" 100 | ConvertFrom-Json)
        
        if (-not $txs) {
            Show-Error "No transactions found or failed to fetch transactions."
            return
        }

        $foundOrphan = $false
        $abandonedCount = 0

        foreach ($tx in $txs) {
            # Print the entire structure of the transaction for debugging purposes
            # Show-Info "Full Transaction Data: $($tx | ConvertTo-Json -Compress)"
            
            # Check if the 'category' exists and matches 'stake-orphan'
            if ($null -eq $tx.category -or $tx.category -ne "stake-orphan") {
                # Show-Warning "Transaction ID: $($tx.txid) does not contain 'stake-orphan' category or is malformed."
                continue
            }

            # If we found an orphaned stake transaction, try to abandon it
            $foundOrphan = $true
            try {
                Show-Info "Attempting to abandon transaction: $($tx.txid)"
                $abandonResponse = & "$PULSARDIR\pulsar-cli.exe" -rpcconnect="$rpcIP" -rpcport="$rpcPort" -rpcuser="$rpcUser" -rpcpassword="$rpcPass" abandontransaction $tx.txid
                Show-Info "Abandon Response: $abandonResponse"
                $abandonedCount++
                Show-Info "Abandoned Transaction: $($tx.txid). Total Abandoned: $abandonedCount"
            } catch {
                if ($_.Exception.Message -like "*error code: -5*") {
                    Show-Warning "Transaction not eligible for abandonment: $($tx.txid)"
                } else {
                    Show-Error "Unexpected error abandoning transaction: $($tx.txid). Error: $($_.Exception.Message)"
                }
            }
        }

        if (-not $foundOrphan) {
            Show-Info "No 'stake-orphan' transactions found."
        }

    } catch {
        Show-Error "Error fetching transactions: $_"
    }
}

function send() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$rpcIP,
        [Parameter(Mandatory=$true)]$rpcPort,
        [Parameter(Mandatory=$true)]$rpcUser,
        [Parameter(Mandatory=$true)]$rpcPass,
        [Parameter(Mandatory=$true)]$utxos
    )

    try {
        # Base and UTXO fees for transaction calculation
        $basefee = 0.00078
        $utxofee = 0.00148

        # Calculate total amount from UTXOs
        $amount = ($utxos | Measure-Object 'amount' -Sum).Sum
        $inputs = @()

        # Collect required input fields for each UTXO
        foreach ($utxo in $utxos) {
            $inputs += @{
                "txid" = "$($utxo.txid)"   # txid must be a string in double quotes
                "vout" = [int]$utxo.vout   # vout must be an integer
            }
        }

        # Convert inputs to JSON
        $inputsJson = $inputs | ConvertTo-Json -Compress | ForEach-Object {$_ -replace '"', '\"'}

        # Calculate the total fee and the output amount after the fee
        $fee = $utxofee * $utxos.Count + $basefee
        $outputAmount = $amount - $fee

        # Prepare the outputs in the correct format (address must be quoted correctly)
        $outputs = @{
            ('"' + $utxos[0].address + '"') = ('"' + [double]$outputAmount + '"')
        }
        $outputsJson = $outputs | ConvertTo-Json -Compress

        # Create the raw transaction
        $rawTransaction = (& "$PULSARDIR\pulsar-cli.exe" -rpcconnect="$rpcIP" -rpcport="$rpcPort" -rpcuser="$rpcUser" -rpcpassword="$rpcPass" createrawtransaction "$inputsJson" "$outputsJson")

        if (-not $rawTransaction) {
            Show-Error "Failed to create raw transaction"
            return
        }

        # Sign the raw transaction
        $signedTransaction = (& "$PULSARDIR\pulsar-cli.exe" -rpcconnect="$rpcIP" -rpcport="$rpcPort" -rpcuser="$rpcUser" -rpcpassword="$rpcPass" signrawtransaction $rawTransaction | ConvertFrom-Json)

        $signed = $signedTransaction.hex

        if (-not $signed) {
            Show-Error "Transaction Signing Failed!"
            return
        }

        # Send the signed transaction
        $send = (& "$PULSARDIR\pulsar-cli.exe" -rpcconnect="$rpcIP" -rpcport="$rpcPort" -rpcuser="$rpcUser" -rpcpassword="$rpcPass" sendrawtransaction $signed)
        Show-Info "Transaction Sent: $send"
    } catch {
        Show-Error "Error sending transaction: $_"
    }
}

# Function to control script execution
function startScript() {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]$rpcIP,
        [Parameter(Mandatory=$true)]$rpcPort,
        [Parameter(Mandatory=$true)]$rpcUser,
        [Parameter(Mandatory=$true)]$rpcPass,
        [Parameter(Mandatory=$true)]$minConsolidation,
        [Parameter(Mandatory=$true)]$consolidationInterval,
        [Parameter(Mandatory=$true)]$utxoThreshold
    )

    while ($true) {
        Clear-Host

        echo " "
        echo " "
        echo " "
        echo " "
        echo " "
        
        $currentDateTime = Get-Date -Format "dd-MM-yyyy HH:mm:ss"
        Show-Info "`n$currentDateTime - Starting UTXO Consolidation Process..."

        # Abandon orphaned stake-abandon transactions if enabled
        if ($enableAutoAbandon) {
            abandon -rpcIP "$rpcIP" -rpcPort "$rpcPort" -rpcUser "$rpcUser" -rpcPass "$rpcPass"
        } else {
            Show-Info "Skipping Orphan Abandonment: Disabled by User"
        }

        # Consolidate UTXOs if enabled
        if ($enableConsolidation) {
            consolidate -rpcIP "$rpcIP" -rpcPort "$rpcPort" -rpcUser "$rpcUser" -rpcPass "$rpcPass" -minConsolidation "$minConsolidation" -utxoThreshold "$utxoThreshold"
        } else {
            Show-Info "Skipping UTXO Consolidation: Disabled by User"
        }

        Write-Progress -Activity "Waiting for next consolidation cycle" -PercentComplete 0 -Status "Sleeping for $consolidationInterval seconds..."
        Start-Sleep -Seconds $consolidationInterval
    }
}

# Start the script with user-defined settings
startScript -rpcIP $rpcIP -rpcPort $rpcPort -rpcUser $rpcUser -rpcPass $rpcPass -minConsolidation $minConsolidation -consolidationInterval $consolidationInterval -utxoThreshold $utxoThreshold
