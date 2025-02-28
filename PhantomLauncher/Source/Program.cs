using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Runtime.InteropServices;
using System.Windows.Forms;

class Program
{
    private static Process serverProcess;
    private static Process gameProcess;
    private static readonly string baseDir = AppDomain.CurrentDomain.BaseDirectory;
    private static readonly ManualResetEvent exitEvent = new ManualResetEvent(false);
    private static bool isGameRunning = false;
    private static bool isServerCrashed = false;

    // P/Invoke declarations for console control handling
    [DllImport("Kernel32")]
    private static extern bool SetConsoleCtrlHandler(ConsoleCtrlEventHandler handler, bool add);
    private delegate bool ConsoleCtrlEventHandler(CtrlType sig);
    private static ConsoleCtrlEventHandler _handler;

    private enum CtrlType
    {
        CTRL_C_EVENT = 0,
        CTRL_BREAK_EVENT = 1,
        CTRL_CLOSE_EVENT = 2,
        CTRL_LOGOFF_EVENT = 5,
        CTRL_SHUTDOWN_EVENT = 6
    }

    [STAThread]
    static void Main()
    {
        Application.SetHighDpiMode(HighDpiMode.SystemAware);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        // Close any other running launcher instances
        foreach (var proc in Process.GetProcessesByName(Process.GetCurrentProcess().ProcessName))
        {
            if (proc.Id != Process.GetCurrentProcess().Id)
            {
                try { proc.Kill(true); } catch { }
            }
        }
        // Set up cleanup handler for application exit
        AppDomain.CurrentDomain.ProcessExit += (s, e) => CleanupProcesses();

        // Set up console control handler
        _handler = new ConsoleCtrlEventHandler(ConsoleCtrlHandler);
        SetConsoleCtrlHandler(_handler, true);

        // Window is already hidden as this is now a Windows application

        // Kill any existing instances
        KillExistingProcesses();

        try
        {
            // Start server
            string serverPath = Path.Combine(baseDir, "Server", "CkProjectPhantomServer.exe");
            serverProcess = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = serverPath,
                    Arguments = "-log=\"CkProjectPhantom.log\"",
                    UseShellExecute = true,
                    WorkingDirectory = Path.Combine(baseDir, "Server")
                }
            };
            serverProcess.EnableRaisingEvents = true;
            serverProcess.Exited += ServerProcess_Exited;
            serverProcess.Start();

            // Start game
            string gamePath = Path.Combine(baseDir, "Game", "CkProjectPhantomGame.exe");
            gameProcess = new Process
            {
                StartInfo = new ProcessStartInfo
                {
                    FileName = gamePath,
                    Arguments = "-ExecCmds=\"ps.eos.enabled 0\" -NoWatermark 127.0.0.1:7777",
                    UseShellExecute = true,
                    WorkingDirectory = Path.Combine(baseDir, "Game")
                }
            };
            gameProcess.EnableRaisingEvents = true;
            gameProcess.Exited += (s, e) => 
            { 
                isGameRunning = false;
                // Only trigger exit if this wasn't due to a server crash
                if (!isServerCrashed)
                {
                    KillExistingProcesses();
                    exitEvent.Set();
                }
            };
            gameProcess.Start();
            isGameRunning = true;

            // Wait for exit signal
            exitEvent.WaitOne();
        }
        finally
        {
            CleanupProcesses();
        }
    }

    private static void ServerProcess_Exited(object sender, EventArgs e)
    {
        if (isGameRunning)
        {
            isServerCrashed = true;
            
            // Kill the game process first
            if (gameProcess != null && !gameProcess.HasExited)
            {
                try { gameProcess.Kill(true); } catch { }
            }
            
            MessageBox.Show(
                "Unfortunately, the server closed unexpectedly. Please restart PhantomLauncher.",
                "Server Error",
                MessageBoxButtons.OK,
                MessageBoxIcon.Error
            );
            exitEvent.Set();
        }
        else
        {
            exitEvent.Set();
        }
    }

    private static bool ConsoleCtrlHandler(CtrlType sig)
    {
        switch (sig)
        {
            case CtrlType.CTRL_C_EVENT:
            case CtrlType.CTRL_LOGOFF_EVENT:
            case CtrlType.CTRL_SHUTDOWN_EVENT:
            case CtrlType.CTRL_CLOSE_EVENT:
            case CtrlType.CTRL_BREAK_EVENT:
                CleanupProcesses();
                exitEvent.Set();
                return true;
            default:
                return false;
        }
    }

    private static void CleanupProcesses()
    {
        try
        {
            KillExistingProcesses();
        }
        catch (Exception)
        {
            // Ensure we don't throw during cleanup
        }
    }

    private static void KillExistingProcesses()
    {
        foreach (var proc in Process.GetProcessesByName("CkProjectPhantomServer"))
        {
            try { proc.Kill(true); } catch { }
        }
        foreach (var proc in Process.GetProcessesByName("CkProjectPhantomGame"))
        {
            try { proc.Kill(true); } catch { }
        }
    }
}