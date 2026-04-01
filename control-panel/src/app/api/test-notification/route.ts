import { NextResponse } from "next/server";
import { probeHelper } from "@/lib/helper-manager";
import { sendTestNotification } from "@/lib/helper-service";

export const runtime = "nodejs";

export async function POST(request: Request) {
  if (!(await probeHelper())) {
    return NextResponse.json(
      { error: "helper is not running" },
      { status: 503 },
    );
  }

  const payload = (await request.json()) as {
    variant?:
      | "general-notification"
      | "work-notification"
      | "nonwork-notification";
  };

  if (
    payload.variant !== "general-notification" &&
    payload.variant !== "work-notification" &&
    payload.variant !== "nonwork-notification"
  ) {
    return NextResponse.json({ error: "invalid variant" }, { status: 400 });
  }

  return NextResponse.json(await sendTestNotification(payload.variant));
}
