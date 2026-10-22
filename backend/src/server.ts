import { config } from "./config.js";
import { connectMongo } from "./db.js";
import { createApp } from "./app.js";

await connectMongo();
createApp().listen(config.PORT, () => {
  console.log(`[api] escuchando en :${config.PORT}`);
});
