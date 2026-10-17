using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Text.RegularExpressions;

// A loopback-only single-connection protocol fixture; it is not QEMU.
public static class Dash08QmpServer {
    public static int Main(string[] args) {
        if (args.Length != 2) return 2;
        int delay;
        if (!Int32.TryParse(args[1], out delay) || delay < 0 || delay > 2000) return 2;
        TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
        try {
            listener.Start();
            File.WriteAllText(Path.Combine(args[0], "port"), ((IPEndPoint)listener.LocalEndpoint).Port.ToString());
            Stopwatch clock = Stopwatch.StartNew();
            while (!listener.Pending()) {
                if (clock.Elapsed.TotalSeconds > 8) return 3;
                Thread.Sleep(10);
            }
            using (TcpClient client = listener.AcceptTcpClient()) {
                client.ReceiveTimeout = 3000;
                client.SendTimeout = 3000;
                using (NetworkStream stream = client.GetStream())
                using (StreamReader reader = new StreamReader(stream, new UTF8Encoding(false)))
                using (StreamWriter writer = new StreamWriter(stream, new UTF8Encoding(false))) {
                    writer.AutoFlush = true;
                    Thread.Sleep(delay);
                    writer.WriteLine("{\"QMP\":{}}");
                    for (int step = 0; step < 2; step++) {
                        string line = reader.ReadLine();
                        if (line == null) return 0; // caller timeout is an expected negative
                        Match id = Regex.Match(line, "\\\"id\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"");
                        if (!id.Success) return 4;
                        Thread.Sleep(delay);
                        writer.WriteLine("{\"id\":\"" + id.Groups[1].Value + "\",\"return\":{\"running\":true,\"status\":\"running\"}}");
                    }
                }
            }
            return 0;
        }
        catch (IOException) { return 0; } // bounded caller closes its owned socket
        catch (SocketException) { return 0; }
        finally { listener.Stop(); }
    }
}
