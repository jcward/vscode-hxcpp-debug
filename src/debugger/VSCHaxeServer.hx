/****************************************************************************
 * HaxeServer.hx
 *
 * Copyright 2013 TiVo Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 * 
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 ****************************************************************************/

package debugger;

import debugger.CommandLineController;
import debugger.HaxeProtocol;
import debugger.IController;

import cpp.vm.Deque;
import cpp.vm.Thread;

class VSCHaxeServer
{
  private var mController : VSCController;
  private var mSocketQueue : Deque<sys.net.Socket>;
  private var mCommandQueue : Deque<Command>;
  private var mReadCommandQueue : Deque<Bool>;

  /**
   * Creates a server.  This function never returns.
   **/
    public function new(log : String->Void,
                        host : String="localhost",
                        port : Int=6972)
    {
        mController = new VSCController();
        mSocketQueue = new Deque<sys.net.Socket>();
        mCommandQueue = new Deque<Command>();
        mReadCommandQueue = new Deque<Bool>();
        Thread.create(readCommandMain);

        var listenSocket : sys.net.Socket = null;

        while (listenSocket == null) {
            listenSocket = new sys.net.Socket();
            try {
                listenSocket.bind(new sys.net.Host(host), port);
                listenSocket.listen(1);
            }
            catch (e : Dynamic) {
                log("VSCHS: Failed to bind/listen on " + host + ":" + port +
                            ": " + e);
                log("VSCHS: Trying again in 3 seconds.");
                Sys.sleep(3);
                listenSocket.close();
                listenSocket = null;
            }
        }

        //while (true) {

            var socket : sys.net.Socket = null;

            while (socket == null) {
                try {
                    log("VSCHS: Listening for client connection on " +
                                host + ":" + port + " ...");
                    socket = listenSocket.accept();
                }
                catch (e : Dynamic) {
                    log("VSCHS: Failed to accept connection: " + e);
                    log("VSCHS: Trying again in 1 second.");
                    Sys.sleep(1);
                }
            }

            var peer = socket.peer();
            log("VSCHS: Received connection from " + peer.host + ".");

            HaxeProtocol.writeServerIdentification(socket.output);
            HaxeProtocol.readClientIdentification(socket.input);

            // Push the socket to the command thread to read from
            mSocketQueue.push(socket);
            mReadCommandQueue.push(true);

            try {
                while (true) {
                    // Read messages from server and pass them on to the
                    // controller.  But first check the type; only allow
                    // the next prompt to be printed on non-thread messages.
                    var message : Message =
                        HaxeProtocol.readMessage(socket.input);

                    var okToShowPrompt : Bool = false;

                    switch (message) {
                    case ThreadCreated(number):
                    case ThreadTerminated(number):
                    case ThreadStarted(number):
                    case ThreadStopped(number, frameNumber, className,
                                       functionName, fileName, lineNumber):
                    default:
                        okToShowPrompt = true;
                    }

                    controller.acceptMessage(message);

                    if (okToShowPrompt) {
                        // OK to show the next prompt; pop whatever is there
                        // to ensure that there is never more than one element
                        // in there.  This helps with "source" commands that
                        // issue tons of commands in sequence
                        while (mReadCommandQueue.pop(false)) {
                        }
                        mReadCommandQueue.push(true);
                    }
                }
            }
            catch (e : haxe.io.Eof) {
                log("VSCHS: Client disconnected.\n");
            }
            catch (e : Dynamic) {
                log("VSCHS: Error while reading message from client: " + e);
            }
            socket.close();
        //}
    }

    public function readCommandMain()
    {
        while (true) {
            // Get the next socket to use
            var socket = mSocketQueue.pop(true);

            // Read commands from the controller and pass them on to the
            // server
            try {
                while (true) {
                    // Wait until the command prompt should be shown
                    mReadCommandQueue.pop(true);

                    HaxeProtocol.writeCommand
                        (socket.output, mController.getNextCommand());
                }
            }
            catch (e : haxe.io.Eof) {
            }
            catch (e : Dynamic) {
                log("VSCHS: Error while writing command to client: " + e);
                socket.close();
            }
        }
    }
}
