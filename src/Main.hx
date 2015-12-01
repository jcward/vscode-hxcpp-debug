package;

import haxe.io.Input;
import haxe.io.Output;
import haxe.io.Bytes;

import sys.io.Process;

class Main {
  static function main() {
    var log = sys.io.File.append("/tmp/adapter.log", false);
    new DebugAdapter(Sys.stdin(), Sys.stdout(), log);
  }
}

class DebugAdapter {
  var _input:Input;
  var _output:Output;
  var _log:Output;

  var _init_args:Dynamic;
  var _launch_req:Dynamic;

  var _compile_process:Process;
  var _run_process:Process;

  public function new(i:Input, o:Output, log:Output) {
    _input = i;
    _output = o;
    _log = log;

    while (true) {
      read_header();
    }
  }

  function log(s:String) { _log.writeString(s+"\n"); }
  function burn_blank_line():Void
  {
    if (_input.readByte()!=13) log("Protocol error, expected 13");
    if (_input.readByte()!=10) log("Protocol error, expected 10");
  }
  function split_args(str:String):Array<String>
  {
    var r = ~/(?:[^\s"]+|"[^"]*")+/g;
    var args = [];
    r.map(str,
          function(r):String {
            args.push(r.matched(0));
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

    log("Sending response, "+b.length+" bytes:");
    log(json);

    _output.writeString("Content-Length: "+b.length);
    _output.writeByte(13);
    _output.writeByte(10);
    _output.writeByte(13);
    _output.writeByte(10);
    _output.writeBytes(b, 0, b.length);
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
        var runCommand:String = null;
        var runPath:String = null;
        for (arg in (_launch_req.arguments.args:Array<String>)) {
          var eq = arg.indexOf('=');
          var name = arg.substr(0, eq);
          var value = arg.substr(eq+1);
          log("Arg "+name+" is "+value);
          switch name {
            case "compileCommand": compileCommand = value;
            case "compilePath": compilePath = value;
            case "runCommand": runCommand = value;
            case "runPath": runPath = value;
            default: log("Unknown arg name '"+name+"'"); do_disconnect();
          }
        }

        var success = true;
        var did_compile = false;
        if (compileCommand!=null) {
          log("Compiling...");
          _compile_process = start_process(compileCommand, compilePath);

          // Blocks until complete:
          success = (_compile_process.exitCode()==0);
          var output = _compile_process.stdout.readAll();
          log("Compile "+(success ? "succeeded!" : "FAILED!"));
          log(output.getString(0, output.length));

          did_compile = (success==true);
        }

        if (success) {
          if (runCommand!=null) {
            _run_process = start_process(runCommand, runPath);
          } else {
            success = false;
            response.message = (did_compile ? "Compile successful, but " : "") +
              "runCommand was not specified.";
          }
        } else {
          success = false;
          response.message = "Compile failed. See <todo: logfile>.";
        }

        response.success = success;
        send_response(response);
      }

      case "pause": {
        //{"type":"request","seq":3,"command":"pause","arguments":{"threadId":0}}
      }

      case "disconnect": {
        do_disconnect();
      }
    }
  }

  function do_disconnect(send_message:Bool=false):Void
  {
    if (_run_process!=null) {
      _run_process.kill();
    }
    if (send_message) {
      log("Sending disconnect message to VSCode");
      send_response({"type":"request","seq":1,"command":"disconnect","arguments":{"extensionHostData":{"restart":false}}});
    }
    log("Disconnecting...");
    Sys.exit(0);
  }

  function start_process(cmd:String, path:String):Process
  {
    var old = Sys.getCwd();
    Sys.setCwd(path);
    var args = split_args(cmd);
    log("args: "+args.join(", "));
    var proc = new sys.io.Process(args.shift(), args);
    Sys.setCwd(old);
    return proc;
  }
}
