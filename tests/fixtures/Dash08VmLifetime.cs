using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;

// Source-only disposable simulated VM. It owns no VM, network port or user file.
// A stop marker or the hard lifetime bound ends it; the harness must verify exit.
public static class Dash08VmLifetime {
    public static int Main(string[] args) {
        if (args.Length != 1 || !Directory.Exists(args[0])) return 2;
        string root = Path.GetFullPath(args[0]);
        using (Process self = Process.GetCurrentProcess()) {
            string identity = self.Id.ToString(CultureInfo.InvariantCulture) + "\n" +
                self.StartTime.ToUniversalTime().Ticks.ToString(CultureInfo.InvariantCulture);
            File.WriteAllText(Path.Combine(root, "child.identity"), identity, new UTF8Encoding(false));
        }
        Stopwatch clock = Stopwatch.StartNew();
        int ticks = 0;
        while (clock.Elapsed.TotalSeconds < 30 && !File.Exists(Path.Combine(root, "stop"))) {
            File.WriteAllText(Path.Combine(root, "heartbeat"), (++ticks).ToString(CultureInfo.InvariantCulture));
            Console.Out.WriteLine("fixture-stdout");
            Console.Error.WriteLine("fixture-stderr");
            Thread.Sleep(100);
        }
        return 0;
    }
}
