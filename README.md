# vscode-haxe-debug

Installation
------------

Place (or symlink) the `vscode-haxe-debug` folder in your VSCode extensions directory:
- Linux: `$HOME/.vscode/extensions`
- Mac: `$HOME/.vscode/extensions`
- Windows: `%USERPROFILE%\.vscode\extensions`

(If it's running, restart Visual Studio Code after installing the extension.)

Note: This extension doesn't provide language support / syntax highlight. For that, install https://github.com/nadako/vscode-haxe in your extensions directory in the same way.

Usage
-----

In your project, add a .vscode folder with a launch.json file in it. See example launch.json files in the [test CLI project](https://github.com/jcward/vscode-hxcpp-debug/tree/master/test%20cli) or the [test OpenFL project](https://github.com/jcward/vscode-hxcpp-debug/tree/master/test%20openfl). You may need to update some of the parameters -- these tell the extension how to compile and launch your project:

```
	"compilePath=${workspaceRoot}",
	"compileCommand=openfl build linux -debug -DHXCPP_DEBUGGER",
	"runPath=${workspaceRoot}/Export/linux64/cpp/bin/",
	"runCommand=DisplayingABitmap",
	"runInTerminal=false"
```

Open your project folder in Visual Studio Code. 

TODO: launch debugger

Potential errors
----------------

**Configured debug type 'hxcpp' is not supported** - the extension is not properly installed in your `.vscode/extensions` directory. Ensure the `vscode-hxcpp-debug` directory is there, and contains the package.json file. Try restarting VSCode.


Development notes
-----------------

VSC documentation: 
- https://code.visualstudio.com/docs/extensions/example-debuggers
- https://code.visualstudio.com/docs/extensionAPI/api-debugging

HXCPP debugger:
- Existing CLI debugger: https://github.com/HaxeFoundation/hxcpp-debugger

Dan's haxe extension: https://github.com/nadako/vscode-haxe
