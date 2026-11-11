using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using Makaretu.Dns;

namespace Couchpad;

/// <summary>
/// TCP listener advertised over Bonjour (mDNS), speaking protocol v2 (see SecureChannel.cs):
/// a plain-text key exchange, then every line encrypted. A phone must authenticate inside the
/// channel with a proof over the transcript before any input is accepted.
/// </summary>
sealed class Server
{
    readonly int port;
    readonly Action onChange;
    readonly TcpListener listener;
    readonly HashSet<TcpClient> clients = new();
    readonly HashSet<TcpClient> authenticated = new();
    readonly object gate = new();
    ServiceDiscovery? discovery;
    CancellationTokenSource cts = new();

    public string Status { get; private set; } = "Starting…";

    public Server(int port, Action onChange)
    {
        this.port = port;
        this.onChange = onChange;
        listener = new TcpListener(IPAddress.Any, port);
    }

    public void Start()
    {
        try
        {
            listener.Start();
        }
        catch (SocketException e)
        {
            Set($"Could not listen on port {port}: {e.Message}");
            return;
        }

        try
        {
            discovery = new ServiceDiscovery();
            discovery.Advertise(new ServiceProfile(Environment.MachineName, "_couchpad._tcp", (ushort)port));
        }
        catch (Exception e)
        {
            // The phone can still connect by IP address.
            Set($"Bonjour failed ({e.Message}); use the address below");
        }

        _ = AcceptLoop(cts.Token);
        Report();
    }

    public void Stop()
    {
        cts.Cancel();
        discovery?.Dispose();
        listener.Stop();
        DisconnectAll();
    }

    /// <summary>Drops every phone; they will have to pair again.</summary>
    public void DisconnectAll()
    {
        List<TcpClient> all;
        lock (gate) all = clients.ToList();
        foreach (var c in all) Drop(c);
    }

    async Task AcceptLoop(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(token); }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException) { continue; }

            client.NoDelay = true;
            lock (gate) clients.Add(client);
            _ = Serve(client, token);
        }
    }

    async Task Serve(TcpClient client, CancellationToken token)
    {
        var buffer = new FrameBuffer();
        var chunk = new byte[65536];
        using var privateKey = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);
        FrameCipher? send = null, recv = null;
        byte[] transcript = Array.Empty<byte>();
        var isAuthenticated = false;
        try
        {
            using var stream = client.GetStream();
            while (!token.IsCancellationRequested)
            {
                var n = await stream.ReadAsync(chunk, token);
                if (n == 0) break;
                buffer.Append(chunk.AsSpan(0, n));

                if (send == null)
                {
                    // Plain-text handshake: exactly one line, "v2 <client public key>".
                    var line = buffer.NextLine();
                    if (line == null) continue;
                    var parts = line.Split(' ');
                    if (parts.Length != 2 || parts[0] != "v2") break;
                    var clientKey = Convert.FromBase64String(parts[1]);
                    var nonce = RandomNumberGenerator.GetBytes(16);
                    var hostKey = SecureChannel.RawPublicKey(privateKey);
                    var key = SecureChannel.SessionKey(privateKey, clientKey, nonce);
                    transcript = SecureChannel.Transcript(clientKey, hostKey, nonce);
                    send = new FrameCipher(key, 1);
                    recv = new FrameCipher(key, 0);
                    await stream.WriteAsync(Encoding.UTF8.GetBytes($"v2 {Convert.ToBase64String(hostKey)} {Convert.ToBase64String(nonce)}\n"), token);
                }

                byte[]? body;
                while ((body = buffer.NextFrame()) != null)
                {
                    var line = recv!.Open(body);
                    if (isAuthenticated)
                    {
                        Injector.Handle(line);
                        continue;
                    }

                    // Anything before "auth" is dropped, never refused: a refusal makes the phone discard its token.
                    var parts = line.Split(' ');
                    if (parts.Length != 3 || parts[0] != "auth") continue;
                    var proof = Convert.FromBase64String(parts[2]);
                    var captured = transcript;
                    bool Matches(string secret) => SecureChannel.ProofMatches(proof, secret, captured, SecureChannel.ClientTag);
                    var issued = parts[1] switch
                    {
                        "token" => Pairing.TokenWhere(Matches),
                        "code" => Pairing.Pair(Matches),
                        _ => null,
                    };
                    if (issued != null)
                    {
                        isAuthenticated = true;
                        lock (gate) authenticated.Add(client);
                        var hostProof = SecureChannel.Proof(issued, transcript, SecureChannel.HostTag);
                        await stream.WriteAsync(send.Seal($"ok {issued} windows {Convert.ToBase64String(hostProof)}"), token);
                        // Every address this PC has, so the phone can still reach it away from home (VPN).
                        var addresses = HostAddresses.IPv4();
                        if (addresses.Count > 0)
                            await stream.WriteAsync(send.Seal($"addrs {port} {string.Join(" ", addresses)}"), token);
                        Report();
                    }
                    else
                    {
                        // One guess per connection: say no, then hang up.
                        await stream.WriteAsync(send.Seal("nope"), token);
                        goto done;
                    }
                }
            }
            done: ;
        }
        catch (Exception) { /* connection went away, or not a Couchpad peer */ }
        finally
        {
            send?.Dispose();
            recv?.Dispose();
            Drop(client);
        }
    }

    void Drop(TcpClient client)
    {
        bool wasAuthenticated;
        lock (gate)
        {
            if (!clients.Remove(client)) return;
            wasAuthenticated = authenticated.Remove(client);
        }
        try { client.Close(); } catch (Exception) { }
        // Never leave a key or mouse button stuck down when the phone goes away.
        if (wasAuthenticated) Injector.ReleaseAll();
        Report();
    }

    void Report()
    {
        int n;
        lock (gate) n = authenticated.Count;
        Set(n == 0 ? "Waiting for iPhone…" : n == 1 ? "1 iPhone connected" : $"{n} iPhones connected");
    }

    void Set(string status)
    {
        Status = status;
        onChange();
    }
}
