using System;
using System.IO;
using System.Text;

// Compiled into a temporary directory by the Windows tests, never committed as a
// binary. Main receives the actual OS/CRT argument tokens, independent of a
// PowerShell script parser. Base64 keeps quotes/newlines/Unicode unambiguous.
internal static class NativeArguments
{
    private static int Main(string[] arguments)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        if (arguments.Length == 1 && arguments[0] == "--stdin-byte-count")
        {
            // Count raw bytes so a text decoder cannot consume or hide a BOM.
            using (Stream input = Console.OpenStandardInput())
            {
                byte[] buffer = new byte[4096];
                long total = 0;
                int count;
                while ((count = input.Read(buffer, 0, buffer.Length)) > 0)
                {
                    total += count;
                }
                Console.WriteLine(total);
            }
            return 0;
        }
        Console.WriteLine(arguments.Length);
        foreach (string argument in arguments)
        {
            Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(argument)));
        }
        return 0;
    }
}
