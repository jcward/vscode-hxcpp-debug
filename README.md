# vscode-hxcpp-debug

**Status:** Currently inactive. Check out these alternatives:

- Vshaxe's [HXCPP debugger](https://github.com/vshaxe/hxcpp-debugger) plugin (available directly from [the marketplace](https://marketplace.visualstudio.com/items?itemName=vshaxe.hxcpp-debugger)).
- Alternately, Proletariat Games' [unreal.hx fork of this repo](https://github.com/proletariatgames/vscode-hxcpp-debug/tree/unreal.hx) (which has more recent commits).

---

**Previous status:** Beta, somewhat stable, feel free to file issues or check those [currently outstanding](https://github.com/jcward/vscode-hxcpp-debug/issues).

**Latest updates:**

- May 17, 2017: Added `test nme`
  - Tested working: vscode 1.11.1, `test nme` with haxe 3.4.2, hxcpp 3.4.90, nme 5.7.1, linux64
  - Tested working: vscode 1.11.1, `test openfl` with haxe 3.4.2, hxcpp 3.4.90, openfl 5.0.0, lime 4.1.0, linux64
- Mar 20, 2017: Hugh [recently fixed](https://github.com/HaxeFoundation/hxcpp-debugger/issues/17) hxcpp-debugger breakpoints and step-over, available in [hxcpp 3.4.69](http://nmehost.com/hxcpp/), though removing breakpoints is still an issue - see [issue #50](https://github.com/jcward/vscode-hxcpp-debug/issues/50). Tested working combo: Haxe 3.4, VSCode 1.8, hxcpp 3.4.69.

## About

The `vscode-hxcpp-debug` project is a Visual Studio Code extension (a debug
adapter) that allows for debugging hxcpp applications in VSCode. This includes
features like stepping through Haxe code and inspecting variables.

Used in combination with the `vscode-haxe` language extension (which provides syntax highlighting, auto-completion, etc and is available from the extensions marketplace, or the [github repo](https://github.com/jcward/vscode-haxe), it makes VSCode is good cross-platform IDE for developing hxcpp apps.

<img src="https://cloud.githubusercontent.com/assets/2192439/15448839/34b33624-1f2a-11e6-8585-0b583d32e7e1.png" width=500>

Note: This extension doesn't provide language support / syntax highlight. For that, search for
[Haxe in the marketplace](https://marketplace.visualstudio.com/search?term=haxe&target=VSCode&category=All%20categories&sortBy=Relevance).

## Installation

**Pre-requisites:**

1. Download and install [Visual Studio Code](https://code.visualstudio.com/)
2. Install the `hxcpp-debugger` library from git:
```
haxelib git hxcpp-debugger https://github.com/HaxeFoundation/hxcpp-debugger
```

**Install the extension:**

Note: Once this project stabilizes, I'll push it to the marketplace for easier installation.

***Step 1.***  Clone the `vscode-hxcpp-debug` repo into your VSCode extensions directory:

  - Linux: `$HOME/.vscode/extensions`
  - Mac: `$HOME/.vscode/extensions`
  - Windows: `%USERPROFILE%\.vscode\extensions`

e.g.
```
cd ~/.vscode/extensions
git clone https://github.com/jcward/vscode-hxcpp-debug.git
```

***Step 2.***  Build the debug adapter using `haxe build-<platform>.hxml`

e.g.
```
cd ~/.vscode/extensions/vscode-hxcpp-debug
haxe build-linux.hxml
```

***Done!*** If it's running, restart Visual Studio Code after installing the extension.

## Usage

### Setup your project
In your project, add a `.vscode` folder with a `launch.json` file in it. See example `launch.json` files (they have platform-specific build sections for Windows, Linux, & Mac) in the [test CLI project](https://github.com/jcward/vscode-hxcpp-debug/tree/master/test%20cli) or the [test OpenFL project](https://github.com/jcward/vscode-hxcpp-debug/tree/master/test%20openfl).

You will need to update some of the parameters -- these tell the extension how to compile and launch your project, for example:

```
	"compilePath=${workspaceRoot}",
	"compileCommand=openfl build windows -debug -DHXCPP_DEBUGGER",
	"runPath=${workspaceRoot}/Export/linux64/cpp/bin/",
	"runCommand=DisplayingABitmap",
	"runInTerminal=false"
```

Your app needs to:
- include the library (`-lib hxcpp-debugger`)
- be compiled in `-debug` mode
- be compiled with `-D HXCPP_DEBUGGER`

If using OpenFL, add the following to your project.xml file to satisfy the above conditions:
```
	<haxelib name="hxcpp-debugger" if="debug" />
	<haxedef name="HXCPP_DEBUGGER" if="debug"/>
```

Near the entry point of your app, add the following code:

```
#if debug
    new debugger.HaxeRemote(true, "localhost");
#end
```

(In place of localhost, you can use the IP address or hostname of your computer if you're remote debugging a mobile app, for example.)

Open your project folder in Visual Studio Code. 

Select the debugger button on the left (bottom button) and you should see the debug launch configurations (Build and debug, Debug) in the dropdown list:

![image](https://cloud.githubusercontent.com/assets/2192439/11687462/104c31f8-9e44-11e5-8f2c-8fcb60a49022.png)

If you do not see these options, ensure your project folder contains a `.vscode/launch.json` file like the samples given above.

## Troubleshooting

Here are some potential errors you might receive, and how you might resolve them:

- **DebugAdapter bin folder not found on path** - build the debug adapter from `vscode-hxcpp-debug` using `haxe build-<platform>.hxml`
- **Configured debug type 'hxcpp' is not supported** or **No extension installed for 'hxcpp' debugging** - the extension is not properly installed in your `.vscode/extensions` directory. Ensure the `vscode-hxcpp-debug` directory is there, and that it contains the `package.json` file. Try restarting VSCode.
- **Build and debug fails with COMPILE FAILED error** - ensure the `compileCommand` and `compilePath` in your `launch.json` file has the correct command, arguments, and syntax required to build your project.
- **The debugger hangs after compiling** - ensure your `runCommand` and `runPath` in your `launch.json` file has the correct command, arguments, and syntax required to build your project. In addition, ensure you've compiled your project in debug mode, included the debugger library, and inserted the `new HaxeRemote()` hunk of code listed above. 
- **Error: runCommand not found: Main-debug.exe** In general, this means the `runCommand` in your `launch.json` (which should be the executable result of your build, e.g. `MyApp.exe`) is not found. Also make sure your compile and run commands are appropriate for your platfor (see the various configuration sections of the launch.json file in the [sample `.vscode` directory](https://github.com/jcward/vscode-hxcpp-debug/tree/master/test%20cli/.vscode)).
- **Build failed, cannot write Main-debug.exe** or similar. Sometimes your program is still running from an old launch. You may have to start task manager and kill your app before you can build it again.
