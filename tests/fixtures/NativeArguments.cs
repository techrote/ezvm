using System;
using System.Text;

// Compiled into a temporary directory by the Windows tests, never committed as a
// binary. Main receives the actual OS/CRT argument tokens, independent of a
// PowerShell script parser. Base64 keeps quotes/newlines/Unicode unambiguous.
internal static class NativeArguments
{
    private static int Main(string[] arguments)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        Console.WriteLine(arguments.Length);
        foreach (string argument in arguments)
        {
            Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(argument)));
        }
        return 0;
    }
}
