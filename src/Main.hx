package;

import haxe.io.Input;
import haxe.io.Output;
import haxe.io.Bytes;

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

    var response = {
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
        var cwd:String = _launch_req.arguments.cwd;
        log("cwd: "+cwd);
        var program:String = _launch_req.arguments.program;
        if (program.indexOf(cwd)==0) program = program.substr(cwd.length+1);
        log("Program: "+program);

        var old = Sys.getCwd();
        Sys.setCwd(cwd);
        var args = split_args(program);
        log("args: "+args.join(", "));
        var compile = new sys.io.Process(args.shift(), args);
        Sys.setCwd(old);
        var success = (compile.exitCode()==0);
        var output = compile.stdout.readAll();
        log("Compile "+(success ? "succeeded!" : "FAILED!"));
        log(output.getString(0, output.length));
        response.success = success;
        send_response(response);
      }

      case "pause": {
        //{"type":"request","seq":3,"command":"pause","arguments":{"threadId":0}}
      }

      case "disconnect": {
        // TODO: restart
        // {"type":"request","seq":3,"command":"disconnect","arguments":{"extensionHostData":{"restart":true}}}

        log("Disconnecting, TODO: kill app?");
        Sys.exit(0);
      }
    }
  }
}
