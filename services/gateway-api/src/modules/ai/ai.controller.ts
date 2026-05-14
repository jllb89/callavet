import { Body, Controller, Get, Param, Patch, Post, Query, UseGuards } from '@nestjs/common';
import { AuthGuard } from '../auth/auth.guard';
import { AiService } from './ai.service';

@Controller('ai')
@UseGuards(AuthGuard)
export class AiController {
  constructor(private readonly ai: AiService) {}

  @Post('triage')
  runTriage(@Body() body: any) {
    return this.ai.runTriage(body || {});
  }

  @Post('referrals/recommend')
  recommendReferral(@Body() body: any) {
    return this.ai.runReferral(body || {});
  }

  @Post('drafts/consultation-note')
  draftConsultationNote(@Body() body: any) {
    return this.ai.draftNote(body || {});
  }

  @Post('drafts/care-plan')
  draftCarePlan(@Body() body: any) {
    return this.ai.draftCarePlan(body || {});
  }

  @Post('embeddings/generate')
  generateEmbeddings(@Body() body: any) {
    return this.ai.generateEmbeddings(body || {});
  }

  @Get('drafts')
  listDrafts(@Query() query: any) {
    return this.ai.listDrafts(query || {});
  }

  @Patch('drafts/:draftId/review')
  reviewDraft(@Param('draftId') draftId: string, @Body() body: any) {
    return this.ai.reviewDraft(draftId, body || {});
  }

  @Get('events')
  listEvents(@Query() query: any) {
    return this.ai.listEvents(query || {});
  }
}
