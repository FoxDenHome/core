package net.doridian.serverstarter;

public class ServerStarter {
    public static void main(String[] args) {
        String[] hardcodedArgs = {
            "./minecraft-run.sh"
        };

        try {
            new ServerBootstrap().startServer(hardcodedArgs);
        } catch (ServerBootstrap.ServerStartupException e) {
            e.printStackTrace();
            System.exit(1);
        }
    }
}
