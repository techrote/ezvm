using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

// Source-only simulated VM. Its private stop marker or 30-second lifetime ends
// it. No VM, account, guest disk, network port or user file is involved.
public static class Dash08VmLifetime {
    public static int Main(string[] args) {
        if (args.Length < 1 || !Directory.Exists(args[0])) return 2;
        string root = Path.GetFullPath(args[0]);
        using (Process self = Process.GetCurrentProcess()) {
            string identity = self.Id.ToString(CultureInfo.InvariantCulture) + "\n" +
                self.StartTime.ToUniversalTime().Ticks.ToString(CultureInfo.InvariantCulture);
            File.WriteAllText(Path.Combine(root, "child.identity"), identity, new UTF8Encoding(false));
        }
        StringBuilder tokens = new StringBuilder();
        tokens.AppendLine((args.Length - 1).ToString(CultureInfo.InvariantCulture));
        for (int i = 1; i < args.Length; i++)
            tokens.AppendLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(args[i])));
        File.WriteAllText(Path.Combine(root, "arguments"), tokens.ToString(), new UTF8Encoding(false));
        if (Array.IndexOf(args, "--read-stdin") >= 0) {
            Task<int> input = Task.Run(delegate { return Console.OpenStandardInput().ReadByte(); });
            if (!input.Wait(2000)) return 3;
            File.WriteAllText(Path.Combine(root, "stdin-first-byte"), input.Result.ToString(CultureInfo.InvariantCulture));
            if (input.Result != -1) return 4;
        }
        if (Array.IndexOf(args, "--flood") >= 0) {
            Console.Out.Write(new string('O', 131072));
            Console.Error.Write(new string('E', 131072));
        }
        Stopwatch clock = Stopwatch.StartNew();
        using (FileStream heartbeat = new FileStream(Path.Combine(root, "heartbeat"), FileMode.CreateNew,
            FileAccess.Write, FileShare.ReadWrite)) {
            while (clock.Elapsed.TotalSeconds < 30 && !File.Exists(Path.Combine(root, "stop"))) {
                heartbeat.WriteByte(1);
                heartbeat.Flush();
                Console.Out.WriteLine("fixture-stdout");
                Console.Error.WriteLine("fixture-stderr");
                Thread.Sleep(100);
            }
        }
        return 0;
    }
}
