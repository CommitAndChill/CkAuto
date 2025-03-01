PhantomLauncher handles the synchronized launching of both the Server and Game executables. When the Game executable is closed, the Server will also automatically be closed.

Usage instructions:
1. Extract the Server build into a folder named `Server` alongside this exe
2. Extract the Game build into a folder named `Game`
3. Run PhantomLauncher.exe, and it will automatically start both processes
4. When the game is closed, the server will close

This was compiled with the following command line arguments:
* Server: -log="CkProjectPhantom.log"
* Game: -ExecCmds="ps.eos.enabled 0, ck.UI.WatermarkDisplayPolicy 0" 127.0.0.1:7777

