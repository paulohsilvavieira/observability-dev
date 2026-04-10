import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { initalizeTracing } from './otel';
import { LoggerConfig } from './logger.config';
initalizeTracing();

async function bootstrap() {
  const logger = new LoggerConfig();

  const app = await NestFactory.create(AppModule, {
    logger, // Desabilita o logger padrão do NestJS
  });

  await app.listen(process.env.PORT ?? 3000);
  logger.enableLoki();
}
bootstrap();
