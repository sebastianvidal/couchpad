using QRCoder;

namespace Couchpad;

/// <summary>
/// Window with the pairing QR code and digits. The code is live only while this window is
/// open and for at most a minute; the form shows a countdown, an expired state with a
/// "New code" button, and a "Paired" state that closes itself.
/// </summary>
sealed class PairingForm : Form
{
    readonly Func<string> payloadProvider;
    readonly PictureBox picture = new() { SizeMode = PictureBoxSizeMode.Zoom, Dock = DockStyle.Top, Height = 260 };
    readonly Label codeLabel = new() { Dock = DockStyle.Top, Height = 50, TextAlign = ContentAlignment.MiddleCenter, Font = new Font("Consolas", 26, FontStyle.Bold) };
    readonly Label countdown = new() { Dock = DockStyle.Top, Height = 22, TextAlign = ContentAlignment.MiddleCenter, ForeColor = SystemColors.GrayText };
    readonly Label hint = new() { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter, ForeColor = SystemColors.GrayText, Padding = new Padding(12, 0, 12, 8) };
    readonly Button newCode = new() { Text = "New code", Dock = DockStyle.Bottom, Height = 32, Visible = false };
    readonly System.Windows.Forms.Timer tick = new() { Interval = 1000 };

    public PairingForm(Func<string> payloadProvider)
    {
        this.payloadProvider = payloadProvider;
        Text = "Pair with Couchpad";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true;
        ClientSize = new Size(300, 440);
        Controls.Add(hint);
        Controls.Add(newCode);
        Controls.Add(countdown);
        Controls.Add(codeLabel);
        Controls.Add(picture);
        newCode.Click += (_, _) => { Pairing.BeginPairing(); };
        tick.Tick += (_, _) => UpdateCountdown();
        FormClosing += (_, e) => { e.Cancel = true; Hide(); tick.Stop(); Pairing.EndPairing(); }; // keep the form, just hide
        Pairing.OnEvent += ev => { if (IsHandleCreated) BeginInvoke(() => Apply(ev)); };
    }

    /// <summary>Opens the window with a fresh one-minute code.</summary>
    public void ShowPairing()
    {
        Pairing.BeginPairing();
        ShowActive();
        Show();
        Activate();
    }

    void Apply(PairingEvent ev)
    {
        if (!Visible) return;
        switch (ev)
        {
            case PairingEvent.CodeChanged: ShowActive(); break;
            case PairingEvent.Expired: ShowExpired(); break;
            case PairingEvent.Paired: ShowPaired(); break;
        }
    }

    void ShowActive()
    {
        codeLabel.Text = Pairing.Code;
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(payloadProvider(), QRCodeGenerator.ECCLevel.M);
        var png = new PngByteQRCode(data).GetGraphic(8);
        picture.Image?.Dispose();
        picture.Image = Image.FromStream(new MemoryStream(png));
        picture.Visible = true;
        hint.Text = "Scan with Couchpad on your iPhone (or with the Camera app), or type the code. One pairing per code.";
        newCode.Visible = false;
        UpdateCountdown();
        tick.Start();
    }

    void UpdateCountdown()
    {
        var s = Pairing.SecondsRemaining;
        countdown.Text = s > 0 ? $"Expires in 0:{s:D2}" : "";
    }

    void ShowExpired()
    {
        tick.Stop();
        picture.Visible = false;
        codeLabel.Text = "Code expired";
        countdown.Text = "";
        hint.Text = "Codes only work for a minute. Get a new one to pair.";
        newCode.Visible = true;
    }

    async void ShowPaired()
    {
        tick.Stop();
        picture.Visible = false;
        codeLabel.Text = "Paired ✓";
        countdown.Text = "";
        hint.Text = "Your iPhone is connected.";
        newCode.Visible = false;
        await Task.Delay(1500);
        if (Visible) Close();
    }
}

static class PairingUrl
{
    /// <summary>couchpad://pair?name=&lt;host&gt;&amp;addr=&lt;ip&gt;&amp;port=48123&amp;code=&lt;6 digits&gt;[&amp;addrs=&lt;ip&gt;,&lt;ip&gt;…]
    /// <c>addr</c> is the primary address; <c>addrs</c> lists the others (VPN tunnels and the like),
    /// and is left out when there are none. Phones that predate it ignore it.</summary>
    public static string Make(string name, IReadOnlyList<string> addresses, int port, string code) =>
        $"couchpad://pair?name={Uri.EscapeDataString(name)}&addr={Uri.EscapeDataString(addresses.FirstOrDefault() ?? "")}&port={port}&code={code}"
        + (addresses.Count > 1 ? $"&addrs={string.Join(",", addresses.Skip(1))}" : "");
}
