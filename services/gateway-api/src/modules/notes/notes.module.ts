import { Module } from '@nestjs/common';
import { DbModule } from '../db/db.module';
import { NotificationsModule } from '../notifications/notifications.module';
import { NotesController } from './notes.controller';
import { SessionNotesController } from './session-notes.controller';
import { EncountersController } from './encounters.controller';

@Module({
  imports: [DbModule, NotificationsModule],
  controllers: [NotesController, SessionNotesController, EncountersController],
})
export class NotesModule {}
