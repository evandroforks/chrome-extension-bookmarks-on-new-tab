# Minimal Chrome DevTools Protocol transport for the browser smoke test.
# Uses only the .NET APIs available in Windows PowerShell.

function Open-Cdp {
    param([Parameter(Mandatory = $true)][string]$WebSocketUrl)

    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $deadline = [System.Threading.CancellationTokenSource]::new(15000)
    try {
        [void]$socket.ConnectAsync([uri]$WebSocketUrl, $deadline.Token).GetAwaiter().GetResult()
    } catch {
        $socket.Dispose()
        throw
    } finally {
        $deadline.Dispose()
    }

    return [pscustomobject]@{
        Socket = $socket
        NextId = 0
        Events = [System.Collections.Generic.List[object]]::new()
    }
}

function Invoke-Cdp {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$Method,
        [hashtable]$Params = @{}
    )

    if ($Connection.Socket.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
        throw 'CDP socket is not open'
    }

    $Connection.NextId++
    $requestId = $Connection.NextId
    $request = @{id = $requestId; method = $Method; params = $Params}
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(
        (ConvertTo-Json -InputObject $request -Depth 20 -Compress)
    )
    $deadline = [System.Threading.CancellationTokenSource]::new(20000)
    try {
        $segment = [System.ArraySegment[byte]]::new($bytes)
        [void]$Connection.Socket.SendAsync(
            $segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $deadline.Token
        ).GetAwaiter().GetResult()

        while ($true) {
            $buffer = New-Object byte[] 65536
            $stream = [System.IO.MemoryStream]::new()
            try {
                do {
                    $segment = [System.ArraySegment[byte]]::new($buffer)
                    $received = $Connection.Socket.ReceiveAsync($segment, $deadline.Token).GetAwaiter().GetResult()
                    if ($received.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                        throw 'CDP socket closed'
                    }
                    $stream.Write($buffer, 0, $received.Count)
                } while (-not $received.EndOfMessage)
                $message = ConvertFrom-Json -InputObject (
                    [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
                )
            } finally {
                $stream.Dispose()
            }

            if ($null -ne $message.id -and $message.id -eq $requestId) {
                if ($message.error) {
                    throw "CDP $Method failed: $($message.error.code) $($message.error.message)"
                }
                return $message.result
            }
            $Connection.Events.Add($message)
        }
    } finally {
        $deadline.Dispose()
    }
}

function Close-Cdp {
    param([Parameter(Mandatory = $true)]$Connection)
    $Connection.Socket.Dispose()
}
