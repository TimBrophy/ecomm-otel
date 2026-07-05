FROM mcr.microsoft.com/playwright:v1.61.1-jammy
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev
COPY . .
CMD ["node", "simulate.js"]
