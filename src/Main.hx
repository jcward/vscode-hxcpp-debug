package;

import haxe.io.Input;
import haxe.io.Output;
import haxe.io.Bytes;

import sys.io.Process;

import cpp.vm.Thread;
import cpp.vm.Deque;
import cpp.vm.Mutex;

class Main {
  static function main() {
    var log = sys.io.File.append("/tmp/adapter.log", false);
    var input = Sys.stdin();
    if (Sys.args().length>0) {
      trace("Reading file input...");
      input = sys.io.File.read(Sys.args()[0], true);
    }
    new DebugAdapter(input, Sys.stdout(), log);
  }
}

class DebugAdapter {
  var _input:AsyncInput;
  var _output:Output;
  var _log:Output;

  var _init_args:Dynamic;
  var _launch_req:Dynamic;
  var _exception_breakpoints_args:Dynamic;

  var _compile_process:Process;
  var _compile_stdout:AsyncInput;

  var _runCommand:String = null;
  var _runPath:String = null;
  var _runInTerminal:Bool = false;
  var _run_process:Process;

  var _vsc_haxe_server:Thread;

  public function new(i:Input, o:Output, log:Output) {
    _input = new AsyncInput(i);
    _output = o;
    _log = log;
    _log_mutex = new Mutex();

    while (true) {
      if (_input.hasData()) read_header();
      if (_compile_process!=null) read_compile();
      Sys.sleep(0.05);
    }
  }

  var _log_mutex:Mutex;
  function log(s:String) {
    _log_mutex.acquire();
    _log.writeString(Sys.time()+": "+s+"\n");
    _log.flush();
    _log_mutex.release();
  }

  function burn_blank_line():Void
  {
    if (_input.readByte()!=13) log("Protocol error, expected 13");
    if (_input.readByte()!=10) log("Protocol error, expected 10");
  }

  // Let's see how this works in Windows before we go trying to improve it...
  function split_args(str:String):Array<String>
  {
    str = StringTools.replace(str, "\\ ", "_LITERAL_SPACE");
    var r = ~/(?:[^\s"]+|"[^"]*")+/g;
    var args = [];
    r.map(str,
          function(r):String {
            var match = r.matched(0);
            args.push(StringTools.replace(match ,"_LITERAL_SPACE", " "));
            return '';
          });
    return args;
  }

  function read_header():Void
  {
    var b:Int;
    var line:StringBuf = new StringBuf();
    while ((b=_input.readByte())!=10) {
      if (b!=13) line.addChar(b);
    }
    log("Read header line:\n"+line.toString());    
    var values = line.toString().split(':');
    if (values[0]=="Content-Length") {
      burn_blank_line();
      handle_request(read_json(Std.parseInt(values[1])));
    } else {
      log("Ignoring unknown header:\n"+line.toString());
    }
  }

  function read_json(num_bytes:Int):Dynamic
  {
    log("Reading "+num_bytes+" bytes...");
    var json:String = _input.read(num_bytes).getString(0, num_bytes);
    log(json);
    return haxe.format.JsonParser.parse(json);
  }

  function send_response(response:Dynamic):Void
  {
    var json:String = haxe.format.JsonPrinter.print(response);
    var b = Bytes.ofString(json);

    log("Sending "+b.length+" bytes:");
    log(json);

    _output.writeString("Content-Length: "+b.length);
    _output.writeByte(13);
    _output.writeByte(10);
    _output.writeByte(13);
    _output.writeByte(10);
    _output.writeBytes(b, 0, b.length);
  }

  var _event_sequence:Int = 1;
  function send_event(event:Dynamic):Void
  {
    event.seq = _event_sequence++;
    event.type = "event";
    send_response(event);
  }

  function send_output(output:String, category:String='console', add_newline:Bool=true):Void
  {
    // Attempts at seeing all messages ???
    // output = StringTools.replace(output, "\"", "");
    // if (output.length>20) {
    //   output = output.substr(0,20);
    //   add_newline = true;
    // }

    var n = add_newline ? "\n" : "";

    if (output.indexOf("\n")>0) {
      // seems to choke on large (or multi-line) output, send separately
      var lines = output.split("\n");
      for (i in 0...lines.length) {
        var line = lines[i] + (i==lines.length-1 ? n : "\n");
        send_event({"event":"output", "body":{"category":category,"output":line}});
      }
    } else {
      send_event({"event":"output", "body":{"category":category,"output":(output+n)}});
    }
  }

  function handle_request(request:Dynamic):Void
  {
    var command:String = request.command;
    log("Got command: "+command);

    var response:Dynamic = {
      request_seq:request.seq,
      command:request.command,
      success:false
    }

    switch command {
      case "initialize": {
        log("Initializing...");
        _init_args = request.arguments;
        response.success = true;
        send_response(response);
      }
      case "launch": {
        log("Launching...");
        _launch_req = request;
        var compileCommand:String = null;
        var compilePath:String = null;
        for (arg in (_launch_req.arguments.args:Array<String>)) {
          var eq = arg.indexOf('=');
          var name = arg.substr(0, eq);
          var value = arg.substr(eq+1);
          log("Arg "+name+" is "+value);
          switch name {
            case "compileCommand": compileCommand = value;
            case "compilePath": compilePath = value;
            case "runCommand": _runCommand = value;
            case "runPath": _runPath = value;
            case "runInTerminal": _runInTerminal = (value.toLowerCase()=='true');
            default: log("Unknown arg name '"+name+"'"); do_disconnect();
          }
        }

        var success = true;
        if (compileCommand!=null) {
          log("Compiling...");
          send_output("Compiling...");
          send_output("Note: not all build log lines come through to vscode console ???");
          _compile_process = start_process(compileCommand, compilePath);
          _compile_stdout = new AsyncInput(_compile_process.stdout);
        } else {
          if (_runCommand!=null) {
            do_run();
          } else {
            // TODO: terminatedevent...
            log("Compile, but no runCommand, TODO: terminate...");
            success = false;
            response.message = "No compileCmd or runCommand found.";
          }
        }

        response.success = success;
        send_response(response);
      }

      case "pause": {
        //{"type":"request","seq":3,"command":"pause","arguments":{"threadId":0}}
      }

      case "setExceptionBreakpoints": {
        //{"type":"request","seq":3,"command":"setExceptionBreakpoints","arguments":{"filters":["uncaught"]}}
        _exception_breakpoints_args = request.arguments;
        response.success = true;
        send_response(response);
      }

      case "setBreakpoints": {
        //{"type":"request","seq":3,"command":"setBreakpoints","arguments":{"source":{"path":"/home/jward/dev/vscode-hxcpp-debug/test openfl/Source/Main.hx"},"lines":[17]}}
        // TODO: set breakpoints in hxcpp-debugger
        response.success = true;
        var breakpoints = [];
        for (line in (request.arguments.lines:Array<Int>)) {
          breakpoints.push({ verified:true, line:line});
        }
        response.body = { breakpoints:breakpoints }
        send_response(response);
      }

      case "disconnect": {
        do_disconnect();
      }
    }
  }

  function do_run() {
    log("Starting VSCHaxeServer port 6972...");
    _vsc_haxe_server = Thread.create(start_server);
    _vsc_haxe_server.sendMessage(log);

    log("Launching application...");
    send_output("Launching application...");

    _run_process = start_process(_runCommand, _runPath, _runInTerminal);

    send_event({"event":"initialized"});
  }

  function read_compile() {
    // TODO: non-blocking compile process, send stdout as we receive it,
    // handle disconnect
 
    // Blocks until complete:

    var line:StringBuf = new StringBuf();
    var compile_finished:Bool = false;
    while (_compile_stdout.hasData()) {
      try {
        line.addChar(_compile_stdout.readByte());
      } catch (e : haxe.io.Eof) {
        compile_finished = true;
        break;
      }
    }
    if (_compile_stdout.isClosed()) compile_finished = true;

    //var output = compile_process.stdout.readAll();
    var result = line.toString();

    if (result.length>0) {
      log(result);
      send_output(result, 'console', false);
    }

    if (compile_finished) {
      var success = _compile_process.exitCode()==0;
      log("Compile "+(success ? "succeeded!" : "FAILED!"));
      send_output("Compile "+(success ? "succeeded!" : "FAILED!"));
      _compile_process = null;
      _compile_stdout = null;

      if (success) {
        do_run();
      } else {
        do_disconnect();
      }
    }

  }

  function do_disconnect(send_message:Bool=false):Void
  {
    if (_run_process!=null) {
      log("Killing _run_process");
      _run_process.close();
      _run_process.kill(); // TODO, this is not closing the app
      _run_process = null;
    }
    if (_compile_process!=null) {
      log("Killing _compile_process");
      _compile_process.close();
      _compile_process.kill(); // TODO, this is not closing the process
      _compile_process = null;
    }
    if (send_message) {
      log("Sending disconnect message to VSCode");
      send_response({"type":"request","seq":1,"command":"disconnect","arguments":{"extensionHostData":{"restart":false}}});
    }
    log("Disconnecting...");
    Sys.exit(0);
  }

  function start_process(cmd:String, path:String, in_terminal:Bool=false):Process
  {
    var old:String = null;
    if (in_terminal) {
      cmd = "gnome-terminal --working-directory="+path.split(" ").join('\\ ')+" -x ./"+cmd.split(" ").join('\\ ');
    } else {
      old = Sys.getCwd();
      Sys.setCwd(path);
    }
    log("cmd: "+cmd);
    var args = split_args(cmd);
    log("args: "+args.join('|'));
    var display = args.join(" ");
    cmd = args.shift();

    // TODO: file separator for windows? Maybe not necessary for windows
    // as ./ is in the PATH by default?
    if (sys.FileSystem.exists(path+'/'+cmd)) {
      log("Setting ./ prefix");
      cmd = "./"+cmd;
    }

    var proc = new sys.io.Process(cmd, args);
    log("Starting: "+display+", pid="+proc.getPid());
    if (old!=null) Sys.setCwd(old);
    return proc;
  }

  static function start_server():Void
  {
    var log:String->Void = Thread.readMessage(true);
    var vschs = new debugger.VSCHaxeServer(log);
    // fyi, the above constructor function does not return
  }

}

class AsyncInput {
  var _data:Deque<Int>;
  var _closed:Deque<Bool>;
  var _is_closed:Bool = false;

  public function new(i:Input) {
    _data = new Deque<Int>();
    _closed = new Deque<Bool>();
    var t = Thread.create(readInput);
    t.sendMessage(i);
    t.sendMessage(_data);
    t.sendMessage(_closed);
  }

  inline function check_closed():Bool {
    return _is_closed || (_is_closed=_closed.pop(false)==true);
  }

  public function isClosed():Bool { return check_closed(); }

  var buffer:Null<Int> = null;
  public function hasData():Bool // non-blocking
  {
    if (check_closed()) return false;
    if (buffer!=null) return true;
    buffer = _data.pop(false);
    return (buffer!=null);
  }

  public function readByte():Int // blocking
  {
    var rtn:Int = 0;
    if (check_closed()) throw new haxe.io.Eof();
    if (buffer==null) { buffer = _data.pop(true); }
    rtn = buffer;
    buffer = null;
    return rtn;
  }

  public function read(num_bytes:Int):Bytes // blocking
  {
    if (check_closed()) throw new haxe.io.Eof();
    var rtn:Bytes = Bytes.alloc(num_bytes);
    var ptr:Int = 0;
    while (ptr<num_bytes) {
      rtn.set(ptr++, readByte());
      if (_is_closed) break;
    }
    return rtn;
  }

  // Thread
  static var inst = 0;
  static private function readInput()
  {
    var _input:Input = Thread.readMessage(true);
    var _data:Deque<Int> = Thread.readMessage(true);
    var _closed:Deque<Bool> = Thread.readMessage(true);

    var mirror = sys.io.File.append("/tmp/input.bin."+(inst++), false);

    while (true) {
      var b:Int = 0;
      try {
        b = _input.readByte();
      } catch (e:haxe.io.Eof) {
        break;
      }
      mirror.writeByte(b);
      _data.add(b);
    }

    _closed.add(true);
  }
}
