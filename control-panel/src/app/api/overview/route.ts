import { NextResponse } from "next/server";
import { readOverview } from "@/lib/helper-service";

export const runtime = "nodejs";

export async function GET() {
  return NextResponse.json(await readOverview());
}
