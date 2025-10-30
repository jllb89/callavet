import { WebSocketGateway, WebSocketServer, SubscribeMessage, MessageBody, ConnectedSocket } from '@nestjs/websockets';
import { Server, Socket } from 'socket.io';

@WebSocketGateway({ namespace: '/chat', cors: { origin: '*' } })
export class ChatGateway {
  @WebSocketServer()
  server!: Server;

  handleConnection(client: Socket) {
    // TODO: verify Supabase JWT from query/token
    client.emit('presence', { online: true });
  }

  @SubscribeMessage('join')
  onJoin(@MessageBody() data: { roomId: string; userId: string }, @ConnectedSocket() client: Socket){
    client.join(data.roomId);
    this.server.to(data.roomId).emit('presence', { userId: data.userId, joined: true });
  }

  @SubscribeMessage('leave')
  onLeave(@MessageBody() data: { roomId: string; userId: string }, @ConnectedSocket() client: Socket){
    client.leave(data.roomId);
    this.server.to(data.roomId).emit('presence', { userId: data.userId, left: true });
  }

  @SubscribeMessage('typing')
  onTyping(@MessageBody() data: { roomId: string; userId: string; typing: boolean }){
    this.server.to(data.roomId).emit('typing', data);
  }

  @SubscribeMessage('message:new')
  onMessage(@MessageBody() data: { roomId: string; from: string; text: string }){
    const msg = { ...data, id: `msg_${Date.now()}`, ts: Date.now() };
    this.server.to(data.roomId).emit('message:delivery', { id: msg.id, delivered: true });
    this.server.to(data.roomId).emit('message:new', msg);
  }
}
