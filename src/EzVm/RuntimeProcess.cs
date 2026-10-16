using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace EzVm.Dash08 {
    // This is a process/handle boundary, not a supervisor or a job escape.
    // The child owns direct file handles and no caller capture pipe or reader.
    public sealed class RuntimeLaunch {
        public Process Process { get; internal set; }
        public int Pid { get; internal set; }
        public string StartTimeUtc { get; internal set; }
    }

    public static class RuntimeProcess {
        private static readonly object Gate = new object();
        private static readonly IntPtr InvalidHandle = new IntPtr(-1);
        private const uint GenericRead = 0x80000000;
        private const uint GenericWrite = 0x40000000;
        private const uint ShareRead = 1;
        private const uint ShareWrite = 2;
        private const uint CreateNew = 1;
        private const uint OpenExisting = 3;
        private const uint NormalFile = 0x80;
        private const uint StartUseStdHandles = 0x100;
        private const uint ExtendedStartupInfo = 0x00080000;
        private const uint CreateNoWindow = 0x08000000;
        private const uint WaitObject0 = 0;
        private static readonly IntPtr HandleListAttribute = new IntPtr(0x00020002);

        [StructLayout(LayoutKind.Sequential)]
        private struct SecurityAttributes {
            public int Length;
            public IntPtr SecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool InheritHandle;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct StartupInfo {
            public int Size;
            public string Reserved;
            public string Desktop;
            public string Title;
            public uint X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
            public short ShowWindow, Reserved2Size;
            public IntPtr Reserved2, StandardInput, StandardOutput, StandardError;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct StartupInfoEx {
            public StartupInfo StartupInfo;
            public IntPtr AttributeList;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInformation {
            public IntPtr Process, Thread;
            public uint ProcessId, ThreadId;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct FileTime {
            public uint Low, High;
            public long Value { get { return ((long)High << 32) | Low; } }
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(string name, uint access, uint share,
            ref SecurityAttributes attributes, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags,
            IntPtr attribute, IntPtr value, IntPtr size, IntPtr previous, IntPtr returnedSize);
        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr list);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(string application, StringBuilder commandLine,
            IntPtr processAttributes, IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint flags, IntPtr environment, string directory, ref StartupInfoEx startup, out ProcessInformation information);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetProcessTimes(IntPtr process, out FileTime creation,
            out FileTime exit, out FileTime kernel, out FileTime user);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CloseHandle(IntPtr handle);

        private static void Close(ref IntPtr handle) {
            if (handle != IntPtr.Zero && handle != InvalidHandle) CloseHandle(handle);
            handle = IntPtr.Zero;
        }
        private static Exception NativeError(string operation) {
            return new Win32Exception(Marshal.GetLastWin32Error(), operation);
        }

        // commandLine already contains the correctly CRT-quoted executable and tokens.
        // Application is passed separately; no shell, PATH resolution or elevation.
        public static RuntimeLaunch Start(string application, string commandLine,
            string directory, string stdoutPath, string stderrPath) {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT)
                throw new PlatformNotSupportedException("Runtime launch requires Windows.");
            if (String.IsNullOrWhiteSpace(application) || !Path.IsPathRooted(application) ||
                String.IsNullOrEmpty(commandLine) || commandLine.IndexOf('\0') >= 0 || commandLine.Length >= 32767)
                throw new ArgumentException("Runtime launch requires an absolute executable and a bounded, NUL-free command line.");
            if (!Directory.Exists(directory)) throw new DirectoryNotFoundException(directory);
            if (!Path.IsPathRooted(stdoutPath) || !Path.IsPathRooted(stderrPath) ||
                String.Equals(stdoutPath, stderrPath, StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("Runtime stdout and stderr require distinct absolute new file paths.");

            lock (Gate) {
                IntPtr input = IntPtr.Zero, output = IntPtr.Zero, error = IntPtr.Zero;
                IntPtr attributes = IntPtr.Zero, handles = IntPtr.Zero;
                bool initialized = false, created = false;
                ProcessInformation information = new ProcessInformation();
                Process managed = null;
                try {
                    SecurityAttributes security = new SecurityAttributes();
                    security.Length = Marshal.SizeOf(typeof(SecurityAttributes));
                    security.InheritHandle = true;
                    input = CreateFileW("NUL", GenericRead, ShareRead | ShareWrite,
                        ref security, OpenExisting, NormalFile, IntPtr.Zero);
                    if (input == InvalidHandle) throw NativeError("Could not open runtime null input.");
                    output = CreateFileW(stdoutPath, GenericWrite, ShareRead,
                        ref security, CreateNew, NormalFile, IntPtr.Zero);
                    if (output == InvalidHandle) throw NativeError("Could not create runtime stdout log; existing files are never replaced.");
                    error = CreateFileW(stderrPath, GenericWrite, ShareRead,
                        ref security, CreateNew, NormalFile, IntPtr.Zero);
                    if (error == InvalidHandle) throw NativeError("Could not create runtime stderr log; existing files are never replaced.");

                    IntPtr size = IntPtr.Zero;
                    InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                    if (size == IntPtr.Zero) throw NativeError("Could not size runtime handle list.");
                    attributes = Marshal.AllocHGlobal(size);
                    if (!InitializeProcThreadAttributeList(attributes, 1, 0, ref size))
                        throw NativeError("Could not initialize runtime handle list.");
                    initialized = true;
                    handles = Marshal.AllocHGlobal(IntPtr.Size * 3);
                    Marshal.WriteIntPtr(handles, 0, input);
                    Marshal.WriteIntPtr(handles, IntPtr.Size, output);
                    Marshal.WriteIntPtr(handles, IntPtr.Size * 2, error);
                    if (!UpdateProcThreadAttribute(attributes, 0, HandleListAttribute, handles,
                        new IntPtr(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero))
                        throw NativeError("Could not constrain runtime handle inheritance.");

                    StartupInfoEx startup = new StartupInfoEx();
                    startup.StartupInfo.Size = Marshal.SizeOf(typeof(StartupInfoEx));
                    startup.StartupInfo.Flags = StartUseStdHandles;
                    startup.StartupInfo.StandardInput = input;
                    startup.StartupInfo.StandardOutput = output;
                    startup.StartupInfo.StandardError = error;
                    startup.AttributeList = attributes;
                    if (!CreateProcessW(application, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero,
                        true, ExtendedStartupInfo | CreateNoWindow, IntPtr.Zero, directory, ref startup, out information))
                        throw NativeError("Could not create the runtime process.");
                    created = true;

                    FileTime creation, exit, kernel, user;
                    if (!GetProcessTimes(information.Process, out creation, out exit, out kernel, out user))
                        throw NativeError("Could not obtain original runtime process creation evidence.");
                    DateTime start = DateTime.FromFileTimeUtc(creation.Value);
                    managed = Process.GetProcessById(checked((int)information.ProcessId));
                    // Force the managed object to retain its own process handle, then
                    // compare it to the original creation handle before handing off.
                    IntPtr pinnedHandle = managed.Handle;
                    FileTime managedCreation, managedExit, managedKernel, managedUser;
                    if (!GetProcessTimes(pinnedHandle, out managedCreation, out managedExit, out managedKernel, out managedUser))
                        throw NativeError("Could not validate managed runtime process ownership.");
                    if (creation.Value != managedCreation.Value)
                        throw new InvalidOperationException("Runtime process identity changed during launch handoff.");
                    RuntimeLaunch result = new RuntimeLaunch();
                    result.Process = managed;
                    result.Pid = checked((int)information.ProcessId);
                    result.StartTimeUtc = start.ToString("o", System.Globalization.CultureInfo.InvariantCulture);
                    managed = null; // ownership passes to the caller; Dispose does not terminate it
                    return result;
                }
                catch (Exception failure) {
                    if (created) {
                        // Terminate only the exact process HANDLE this invocation created,
                        // never a numeric PID looked up after a possibly failed handoff.
                        TerminateProcess(information.Process, 1);
                        bool exited = WaitForSingleObject(information.Process, 2000) == WaitObject0;
                        throw new InvalidOperationException("Runtime launch handoff failed for PID " + information.ProcessId +
                            (exited ? "; the owned child exited. " : "; child exit could not be confirmed, preserve logs and reconcile ownership. "), failure);
                    }
                    throw;
                }
                finally {
                    if (managed != null) managed.Dispose();
                    Close(ref information.Thread);
                    Close(ref information.Process);
                    if (initialized) DeleteProcThreadAttributeList(attributes);
                    if (attributes != IntPtr.Zero) Marshal.FreeHGlobal(attributes);
                    if (handles != IntPtr.Zero) Marshal.FreeHGlobal(handles);
                    Close(ref input);
                    Close(ref output);
                    Close(ref error);
                }
            }
        }
    }
}
