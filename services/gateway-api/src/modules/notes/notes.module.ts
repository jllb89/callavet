import { Module } from '@nestjs/common';
import { DbModule } from '../db/db.module';
import { NotesController } from './notes.controller';
import { SessionNotesController } from './session-notes.controller';

@Module({
  imports: [DbModule],
  controllers: [NotesController, SessionNotesController],
})
export class NotesModule {}
