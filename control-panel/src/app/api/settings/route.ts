import { NextResponse } from "next/server";
import { probeHelper } from "@/lib/helper-manager";
import { writeSettings } from "@/lib/helper-service";
import { type Settings } from "@/lib/types";

export const runtime = "nodejs";

export async function PUT(request: Request) {
  if (!(await probeHelper())) {
    return NextResponse.json(
      { error: "helper is not running" },
      { status: 503 },
    );
  }

  const payload = (await request.json()) as { settings: Settings };
  return NextResponse.json(await writeSettings(payload.settings));
}
