import { NextResponse } from "next/server";
import { readOverview } from "@/lib/helper-service";
import { startHelper, stopHelper } from "@/lib/helper-manager";

export const runtime = "nodejs";

export async function POST(request: Request) {
  const payload = (await request.json()) as { action?: "start" | "stop" };

  if (payload.action === "start") {
    const started = await startHelper();
    return NextResponse.json({
      started,
      overview: await readOverview(),
    });
  }

  if (payload.action === "stop") {
    await stopHelper();
    return NextResponse.json({
      stopped: true,
      overview: await readOverview(),
    });
  }

  return NextResponse.json({ error: "invalid action" }, { status: 400 });
}
